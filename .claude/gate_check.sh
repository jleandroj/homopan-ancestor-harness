#!/usr/bin/env bash
# gate_check.sh -- Fail-closed PreToolUse gate for Claude Code
# Verifies contract surface hash matches stored gate pass.
# If jq is not available or gate pass is missing/stale -> DENY.
set -euo pipefail

# ── Fail-closed: any unexpected error in this gate => DENY (exit 2) ────────
# Without this, an uncaught error could exit non-2 and be treated as
# non-blocking by the hook runner (fail-open). Explicit deny on ERR.
trap 'echo "DENY: gate_check.sh internal error (fail-closed)." >&2; exit 2' ERR

# ── Derive project root ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GATE_PASS="${SCRIPT_DIR}/.gate_pass"
CLAUDE_MD="${PROJECT_ROOT}/CLAUDE.md"
AGENTS_MD="${PROJECT_ROOT}/agents.md"

# Non-blocking alert: surface a prior PostToolUse logging failure.
if [[ -s "${SCRIPT_DIR}/.posttool_error" ]]; then
  echo "WARN: previous PostToolUse logging reported an error (${SCRIPT_DIR}/.posttool_error); audit log may be incomplete." >&2
fi

# ── Bash write-protection (P0-a) ──────────────────────────────────────────
# Best-effort detection of Bash commands that try to modify a protected
# security file or forge the gate pass. This complements two stronger layers:
#   (1) the Write/Edit/NotebookEdit hardline-deny below, and
#   (2) the gate-pass hash: any actual change to the surface invalidates the
#       pass and blocks every later tool call until 'bash init.sh' is re-run.
# Absolute rule: ANY Bash reference to .gate_pass is denied (only init.sh may
# write it). Obfuscated execution (base64|sh, eval, curl|sh) is handled
# separately by bash_is_obfuscated() below.
bash_writes_protected() {
  local c="$1"
  # Protected = contract surface + the REAL boundary scripts (sandbox/egress).
  local prot='(CLAUDE\.md|agents\.md|gate_check\.sh|bitacora_log\.sh|settings\.json|init\.sh|\.gate_pass|sandbox_run\.sh|_guard\.sh|egress_allowlist\.txt)'

  # 1. Never allow the agent to touch the gate pass via Bash.
  grep -Eq '\.gate_pass' <<<"$c" && return 0

  # Normalized copy: strip quotes and backslashes so >'CLAUDE.md', >"CLAUDE.md"
  # and >C\LAUDE.md cannot hide the target from the patterns below (fuzz P1).
  local n s
  n=$(printf '%s' "$c" | tr -d "\"'" | tr -d '\\')

  for s in "$c" "$n"; do
    # 2. Redirection ( > or >> , optional fd / path prefix) into a protected file.
    grep -Eq '(^|[^0-9])[0-9]*>>?[[:space:]]*([^[:space:]"'"'"';|&]*/)?'"$prot" <<<"$s" && return 0
    # 3. In-place / copy / move / truncate utilities targeting a protected file.
    grep -Eq '(^|[[:space:];&|(])(sed[[:space:]]+-i|perl[[:space:]]+-[A-Za-z]*i|awk[[:space:]]+-i|tee([[:space:]]+-a)?|cp|mv|dd|install|truncate|ln|chmod|chown|rm|shred)([[:space:]]|=).*'"$prot" <<<"$s" && return 0
  done

  # 4. Interpreter writing to a protected file (python/perl/ruby/node/php).
  if grep -Eq '(python|perl|ruby|node|php)' <<<"$c" \
     && grep -Eq "$prot" <<<"$n" \
     && grep -Eq "(open\(|['\"]w['\"]|>>?|writeFile|O_WRONLY|O_CREAT)" <<<"$c"; then
    return 0
  fi

  return 1
}

# ── Obfuscated / remote execution denylist (NEW-P1) ───────────────────────
# Decode-and-run, eval, and fetch-and-run pipelines defeat the static
# write-protection above, so deny them outright in agent Bash calls.
bash_is_obfuscated() {
  local c="$1"
  # base64/xxd/openssl/gpg decoded then piped to a shell
  grep -Eq '(base64|xxd|openssl[[:space:]]+enc|gpg)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh\b' <<<"$c" && return 0
  # remote fetch piped to a shell (egress + exec)
  grep -Eq '(curl|wget|fetch)\b[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh\b' <<<"$c" && return 0
  # eval: deny EXCEPT the standard conda/mamba activation hook
  if grep -Eq '(^|[[:space:];&|(])eval([[:space:]]|$)' <<<"$c"; then
    grep -Eq 'eval[[:space:]]+"?\$\([^)]*\b(conda|mamba|micromamba)\b[^)]*shell' <<<"$c" || return 0
  fi
  return 1
}

# ── Extracted command detector (#12) -- single source of truth, fuzzed in
# tests/test_cmd_detector_fuzz.sh. Sourced AFTER the inline copy so the module
# definitions win; remove the inline copies above once this is in place.
source "${SCRIPT_DIR}/cmd_detector.sh"

# ── jq check (fail-closed) ───────────────────────────────────────────────
for _jqc in "${HOMOPAN_JQ:-}" "${HOME}/miniconda3/envs/homopan_ancestor/bin/jq" "${HOME}/miniconda3/bin/jq" "${HOME}/anaconda3/envs/homopan_ancestor/bin/jq" /usr/bin/jq /bin/jq; do
  if [[ -n "${_jqc}" && -x "${_jqc}" ]]; then export PATH="$(dirname "${_jqc}"):${PATH}"; break; fi
done
unset _jqc 2>/dev/null || true
if ! command -v jq &>/dev/null; then
  # Fallback: known conda locations (#15)
  for candidate in \
    "${HOME}/miniconda3/envs/homopan_ancestor/bin/jq" \
    "${HOME}/miniconda3/bin/jq" \
    "${HOME}/anaconda3/envs/homopan_ancestor/bin/jq" \
    "/usr/bin/jq"; do
    if [[ -x "${candidate}" ]]; then
      export PATH="$(dirname "${candidate}"):${PATH}"
      break
    fi
  done
  if ! command -v jq &>/dev/null; then
    echo "DENY: jq not found (fail-closed)." >&2
    echo "" >&2
    echo "To fix, run one of:" >&2
    echo "  conda install -n homopan_ancestor -c conda-forge jq" >&2
    echo "  sudo apt install jq" >&2
    echo "Then re-run: bash init.sh" >&2
    exit 2
  fi
fi

# ── Parse hook input ─────────────────────────────────────────────────────
# Claude Code sends JSON on stdin for PreToolUse hooks
INPUT=$(cat)
TOOL=$(echo "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null || true)

# ── Bash handling ──────────────────────────────────────────────────────────
if [[ "${TOOL}" == "Bash" ]]; then
  COMMAND=$(echo "${INPUT}" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
  COMMAND_TRIMMED=$(echo "${COMMAND}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  # Allow Bash calls that run ONLY init.sh (exact match, not substring)
  if [[ "${COMMAND_TRIMMED}" == "bash init.sh" || \
        "${COMMAND_TRIMMED}" == "bash ./init.sh" || \
        "${COMMAND_TRIMMED}" == "cd ${PROJECT_ROOT} && bash init.sh" || \
        "${COMMAND_TRIMMED}" == "cd ${PROJECT_ROOT} && bash ./init.sh" ]]; then
    exit 0
  fi

  # Hardline: Bash must not write to protected security files or forge the pass.
  # Applies even with a valid gate pass.
  if bash_writes_protected "${COMMAND}"; then
    echo "DENY: Bash command targets a protected security file or the gate pass." >&2
    echo "Protected: CLAUDE.md, agents.md, gate_check.sh, bitacora_log.sh, settings.json, init.sh, .gate_pass" >&2
    echo "These can only change by editing manually and re-running: bash init.sh" >&2
    exit 2
  fi

  # Hardline: no decode/fetch-and-execute or eval.
  if bash_is_obfuscated "${COMMAND}"; then
    echo "DENY: obfuscated/remote-exec Bash pattern (base64|sh, curl|sh, eval)." >&2
    exit 2
  fi

  # Hardline: clinical/human-subject data is off-limits to Bash (read OR write).
  if grep -Eq 'il10_analisis' <<<"${COMMAND}"; then
    echo "DENY: il10_analisis (human-subject/clinical data) is off-limits to Bash." >&2
    exit 2
  fi
fi

# ── Hardline deny: human-subject/clinical data (realpath, all file tools) ──
# Resolve the target so absolute paths and symlinks cannot bypass the
# settings.json globs; applies to Read/Edit/Write/NotebookEdit (not just Bash).
case "${TOOL}" in
  Read|Edit|Write|NotebookEdit)
    _fp=$(echo "${INPUT}" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
    if [[ -n "${_fp}" ]]; then
      _abs=$(realpath -m "${_fp}" 2>/dev/null || echo "${_fp}")
      _clin=$(realpath -m "${PROJECT_ROOT}/il10_analisis" 2>/dev/null || echo "${PROJECT_ROOT}/il10_analisis")
      if [[ "${_abs}" == "${_clin}" || "${_abs}" == "${_clin}/"* ]]; then
        _al="${HOMOPAN_AUDIT_LOG:-${HOME}/.homopan_audit.jsonl}"
        printf '{"timestamp":"%s","event":"DENY_CLINICAL","tool":"%s","path":"%s"}
'           "$(date -Iseconds 2>/dev/null)" "${TOOL}" "${_abs//\"/\\\"}" >> "${_al}" 2>/dev/null || true
        echo "DENY: ${TOOL} on clinical/human-subject data is off-limits (realpath gate)." >&2
        exit 2
      fi
    fi
    ;;
esac

# Network tools denied (no-egress policy; use scripts/sandbox_run.sh if needed)
case "${TOOL}" in
  WebFetch|WebSearch)
    echo "DENY: ${TOOL} blocked by no-egress policy." >&2
    exit 2
    ;;
esac

# Read-only tools always allowed
case "${TOOL}" in
  Read|Glob|Grep|Task|TaskCreate|TaskUpdate|TaskList|TaskGet|AskUserQuestion)
    exit 0
    ;;
esac

# ── Check gate pass exists ────────────────────────────────────────────────
if [[ ! -f "${GATE_PASS}" ]]; then
  echo "DENY: Gate pass not found. Run 'bash init.sh' first." >&2
  exit 2
fi

# ── Content-based verification (hash of FULL security surface) ────────────
# Must match the same file list as init.sh gate pass generation.
SECURITY_FILES=(
  "${CLAUDE_MD}"
  "${AGENTS_MD}"
  "${SCRIPT_DIR}/gate_check.sh"
  "${SCRIPT_DIR}/cmd_detector.sh"
  "${SCRIPT_DIR}/bitacora_log.sh"
  "${SCRIPT_DIR}/settings.json"
  "${PROJECT_ROOT}/init.sh"
)

for sf in "${SECURITY_FILES[@]}"; do
  if [[ ! -f "${sf}" ]]; then
    echo "DENY: Security file missing: $(basename "${sf}"). Run 'bash init.sh'." >&2
    exit 2
  fi
done

# Fold in the skills/ tree (must match init.sh exactly).
SKILLS_DIR="${SCRIPT_DIR}/skills"
if [[ -d "${SKILLS_DIR}" ]]; then
  SKILLS_HASH=$(find "${SKILLS_DIR}" -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1)
else
  SKILLS_HASH="none"
fi

# Fold in the REAL boundary scripts (sandbox + egress) so tampering with them
# invalidates the pass (must match init.sh exactly).
BOUNDARY_FILES=(
  "${PROJECT_ROOT}/scripts/sandbox_run.sh"
  "${PROJECT_ROOT}/scripts/net_wrappers/_guard.sh"
  "${PROJECT_ROOT}/scripts/net_wrappers/curl"
  "${PROJECT_ROOT}/scripts/net_wrappers/wget"
  "${PROJECT_ROOT}/egress_allowlist.txt"
)
BOUNDARY_HASH=$(sha256sum "${BOUNDARY_FILES[@]}" 2>/dev/null | sha256sum | cut -d' ' -f1)

CURRENT_HASH=$( { sha256sum "${SECURITY_FILES[@]}"; printf 'skills:%s\n' "${SKILLS_HASH}"; printf 'boundary:%s\n' "${BOUNDARY_HASH}"; } 2>/dev/null | sha256sum | cut -d' ' -f1)
STORED_HASH=$(head -1 "${GATE_PASS}" | cut -d' ' -f1)

if [[ "${CURRENT_HASH}" != "${STORED_HASH}" ]]; then
  echo "DENY: Security surface changed since last init.sh run." >&2
  echo "Files in surface: CLAUDE.md, agents.md, gate_check.sh, bitacora_log.sh, settings.json, init.sh" >&2
  exit 2
fi

# ── Hardline deny: security files are NEVER writable by the agent ──────────
# Even with a valid gate pass, these files cannot be modified.
# To change them, the user must edit manually and re-run init.sh.
if [[ "${TOOL}" == "Write" || "${TOOL}" == "Edit" || "${TOOL}" == "NotebookEdit" ]]; then
  FILE_PATH=$(echo "${INPUT}" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
  if [[ -n "${FILE_PATH}" ]]; then
    # Resolve to absolute path for comparison
    ABS_PATH=$(realpath -m "${FILE_PATH}" 2>/dev/null || echo "${FILE_PATH}")
    HARDLINE_DENY=(
      "${CLAUDE_MD}"
      "${AGENTS_MD}"
      "${SCRIPT_DIR}/gate_check.sh"
      "${SCRIPT_DIR}/cmd_detector.sh"
      "${SCRIPT_DIR}/bitacora_log.sh"
      "${SCRIPT_DIR}/settings.json"
      "${SCRIPT_DIR}/.gate_pass"
      "${PROJECT_ROOT}/init.sh"
      "${PROJECT_ROOT}/scripts/sandbox_run.sh"
      "${PROJECT_ROOT}/scripts/net_wrappers/_guard.sh"
      "${PROJECT_ROOT}/scripts/net_wrappers/curl"
      "${PROJECT_ROOT}/scripts/net_wrappers/wget"
      "${PROJECT_ROOT}/egress_allowlist.txt"
    )
    for protected in "${HARDLINE_DENY[@]}"; do
      PROTECTED_ABS=$(realpath -m "${protected}" 2>/dev/null || echo "${protected}")
      if [[ "${ABS_PATH}" == "${PROTECTED_ABS}" ]]; then
        echo "DENY: $(basename "${protected}") is a protected security file." >&2
        echo "Security files cannot be modified by the agent." >&2
        echo "Edit manually and re-run: bash init.sh" >&2
        exit 2
      fi
    done
  fi
fi

# ── Gate pass is valid ────────────────────────────────────────────────────
exit 0
