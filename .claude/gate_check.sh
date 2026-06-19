#!/usr/bin/env bash
# gate_check.sh -- Fail-closed PreToolUse gate for Claude Code
# Verifies contract surface hash matches stored gate pass.
# If jq is not available or gate pass is missing/stale -> DENY.
set -euo pipefail

# ── Derive project root ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GATE_PASS="${SCRIPT_DIR}/.gate_pass"
CLAUDE_MD="${PROJECT_ROOT}/CLAUDE.md"
AGENTS_MD="${PROJECT_ROOT}/agents.md"

# ── Bash write-protection (P0-a) ──────────────────────────────────────────
# Best-effort detection of Bash commands that try to modify a protected
# security file or forge the gate pass. This complements two stronger layers:
#   (1) the Write/Edit/NotebookEdit hardline-deny below, and
#   (2) the gate-pass hash: any actual change to the surface invalidates the
#       pass and blocks every later tool call until 'bash init.sh' is re-run.
# Absolute rule: ANY Bash reference to .gate_pass is denied (only init.sh may
# write it). Obfuscated writes (base64|bash, eval) are out of scope here and
# are caught after the fact by layer (2).
bash_writes_protected() {
  local c="$1"
  local prot='(CLAUDE\.md|agents\.md|gate_check\.sh|bitacora_log\.sh|settings\.json|init\.sh|\.gate_pass)'

  # 1. Never allow the agent to touch the gate pass via Bash.
  grep -Eq '\.gate_pass' <<<"$c" && return 0

  # 2. Redirection ( > or >> , optional fd / path prefix) into a protected file.
  grep -Eq '(^|[^0-9])[0-9]*>>?[[:space:]]*([^[:space:]"'"'"';|&]*/)?'"$prot" <<<"$c" && return 0

  # 3. In-place / copy / move / truncate utilities targeting a protected file.
  grep -Eq '(^|[[:space:];&|(])(sed[[:space:]]+-i|perl[[:space:]]+-[A-Za-z]*i|awk[[:space:]]+-i|tee([[:space:]]+-a)?|cp|mv|dd|install|truncate|ln|chmod|chown|rm|shred)([[:space:]]|=).*'"$prot" <<<"$c" && return 0

  # 4. Interpreter writing to a protected file (python/perl/ruby/node/php).
  if grep -Eq '(python|perl|ruby|node|php)' <<<"$c" \
     && grep -Eq "$prot" <<<"$c" \
     && grep -Eq "(open\(|['\"]w['\"]|>>?|writeFile|O_WRONLY|O_CREAT)" <<<"$c"; then
    return 0
  fi

  return 1
}

# ── jq check (fail-closed) ───────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  # Try known conda locations
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
fi

# Read-only tools always allowed
case "${TOOL}" in
  Read|Glob|Grep|WebFetch|WebSearch|Task|TaskCreate|TaskUpdate|TaskList|TaskGet|AskUserQuestion)
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

CURRENT_HASH=$(sha256sum "${SECURITY_FILES[@]}" 2>/dev/null | sha256sum | cut -d' ' -f1)
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
      "${SCRIPT_DIR}/bitacora_log.sh"
      "${SCRIPT_DIR}/settings.json"
      "${SCRIPT_DIR}/.gate_pass"
      "${PROJECT_ROOT}/init.sh"
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
