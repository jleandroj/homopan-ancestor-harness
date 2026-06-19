#!/usr/bin/env bash
# apply_protected_p1_p3.sh -- apply the P1-P3 edits that touch HARDENED files
# the agent is forbidden to write (permissions.deny + gate hardline):
#   init.sh, .claude/gate_check.sh, .claude/bitacora_log.sh,
#   scripts/net_wrappers/_guard.sh
#
# YOU (the human operator) run this; you have the permissions the agent lacks.
# It is IDEMPOTENT and FAIL-LOUD: every edit asserts its anchor exists and is
# applied exactly once; if anything is off it aborts WITHOUT modifying files.
#
#   1. Review this script.
#   2. bash patches/apply_protected_p1_p3.sh
#   3. bash init.sh         # regenerate the gate pass over the new surface
#   4. bash verify.sh       # confirm all self-tests pass
#
# Covers:
#   #12  gate_check.sh sources the extracted .claude/cmd_detector.sh, and the
#        module is folded into the security-surface hash (init.sh + gate_check)
#        and the hardline-deny list.
#   #13  _guard.sh: case-insensitive host match + deny redirect-following
#        (curl -L / forced wget --max-redirect=0) whose target the guard can't see.
#   #8/#10  bitacora_log.sh: every audit line carries run_id / agent / session.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import sys, io, os
root = sys.argv[1]

def edit(path, repls):
    p = os.path.join(root, path)
    with io.open(p, encoding="utf-8") as f:
        s = f.read()
    for old, new, n in repls:
        if new in s and old not in s:
            print(f"  [skip] {path}: already applied")
            continue
        c = s.count(old)
        assert c == n, f"ANCHOR MISMATCH in {path}: expected {n} of <<{old[:60]}...>>, found {c}"
        s = s.replace(old, new)
    with io.open(p, "w", encoding="utf-8") as f:
        f.write(s)
    print(f"  [ok]   {path}")

# ── #12: init.sh -- add cmd_detector.sh to the security surface ───────────
edit("init.sh", [(
'''  "${CLAUDE_DIR}/gate_check.sh"
  "${CLAUDE_DIR}/bitacora_log.sh"
  "${CLAUDE_DIR}/settings.json"
  "${PROJECT_ROOT}/init.sh"
)

mkdir -p "${CLAUDE_DIR}"''',
'''  "${CLAUDE_DIR}/gate_check.sh"
  "${CLAUDE_DIR}/cmd_detector.sh"
  "${CLAUDE_DIR}/bitacora_log.sh"
  "${CLAUDE_DIR}/settings.json"
  "${PROJECT_ROOT}/init.sh"
)

mkdir -p "${CLAUDE_DIR}"''', 1)])

# ── #12: gate_check.sh -- source the module + fold it into hash + hardline ─
edit(".claude/gate_check.sh", [
 # (a) source the extracted module (it overrides the inline copy; single truth)
 ('''# ── jq check (fail-closed) ───────────────────────────────────────────────''',
  '''# ── Extracted command detector (#12) -- single source of truth, fuzzed in
# tests/test_cmd_detector_fuzz.sh. Sourced AFTER the inline copy so the module
# definitions win; remove the inline copies above once this is in place.
source "${SCRIPT_DIR}/cmd_detector.sh"

# ── jq check (fail-closed) ───────────────────────────────────────────────''', 1),
 # (b) runtime security-surface hash includes the module
 ('''  "${SCRIPT_DIR}/gate_check.sh"
  "${SCRIPT_DIR}/bitacora_log.sh"''',
  '''  "${SCRIPT_DIR}/gate_check.sh"
  "${SCRIPT_DIR}/cmd_detector.sh"
  "${SCRIPT_DIR}/bitacora_log.sh"''', 1),
 # (c) hardline-deny writes to the module
 ('''      "${SCRIPT_DIR}/gate_check.sh"
      "${SCRIPT_DIR}/bitacora_log.sh"''',
  '''      "${SCRIPT_DIR}/gate_check.sh"
      "${SCRIPT_DIR}/cmd_detector.sh"
      "${SCRIPT_DIR}/bitacora_log.sh"''', 1),
])

# ── #13: _guard.sh -- case-insensitive match + redirect denial ────────────
edit("scripts/net_wrappers/_guard.sh", [
 ('''  _host_allowed() {
    local h="$1" e
    [[ -f "$allowlist" ]] || return 1
    while IFS= read -r e; do
      e="${e%%#*}"; e="${e// /}"; [[ -z "$e" ]] && continue
      [[ "$h" == "$e" || "$h" == *."$e" ]] && return 0
    done < "$allowlist"
    return 1
  }''',
  '''  _host_allowed() {
    local h="${1,,}" e                       # hostnames are case-insensitive
    [[ -f "$allowlist" ]] || return 1
    while IFS= read -r e; do
      e="${e%%#*}"; e="${e// /}"; e="${e,,}"; [[ -z "$e" ]] && continue
      [[ "$h" == "$e" || "$h" == *."$e" ]] && return 0
    done < "$allowlist"
    return 1
  }''', 1),
 # Redirect handling: a server can bounce the request to a host the guard never
 # vetted. Deny curl's follow flags; force wget to not follow cross-host.
 ('''  # 1. URLs on the command line
  local a''',
  '''  # 0. Redirect-following defeats pre-validation (target host is unseen).
  local a
  for a in "$@"; do
    case "$a" in
      -L|--location|--location-trusted) _deny "redirect-following (${a}) not allowed: target host cannot be pre-validated" ;;
    esac
  done

  # 1. URLs on the command line''', 1),
 # For wget, hard-cap redirects so the validated host is the only host fetched.
 ('''  # Resolve the real tool, skipping this wrapper directory.''',
  '''  # wget follows redirects by default; pin it so only the vetted host is hit.
  [[ "$tool" == "wget" ]] && set -- --max-redirect=0 "$@"

  # Resolve the real tool, skipping this wrapper directory.''', 1),
])

# ── #8/#10: bitacora_log.sh -- run_id / agent / session on every line ──────
edit(".claude/bitacora_log.sh", [
 # capture provenance once, near the timestamp. Identity is sourced from the
 # HOOK PAYLOAD first (Claude Code puts session_id/cwd on stdin -> canonical and
 # always populated), then env vars, then "unknown". JQ_BIN is already resolved
 # above; the bash-pure branch mirrors the grep/sed used for tool_name.
 ('''INPUT=$(cat)
TIMESTAMP=$(date -Iseconds)''',
  '''INPUT=$(cat)
TIMESTAMP=$(date -Iseconds)
if [[ -n "${JQ_BIN}" ]]; then
  _SID=$(printf '%s' "${INPUT}" | "${JQ_BIN}" -r '.session_id // empty' 2>/dev/null || true)
  _CWD=$(printf '%s' "${INPUT}" | "${JQ_BIN}" -r '.cwd // empty' 2>/dev/null || true)
else
  _SID=$(printf '%s' "${INPUT}" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//' || true)
  _CWD=$(printf '%s' "${INPUT}" | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//' || true)
fi
RUN_ID_TAG="${HOMOPAN_RUN_ID:-unknown}"
AGENT_TAG="${HOMOPAN_AGENT:-${CLAUDE_AGENT:-unknown}}"
SESSION_TAG="${_SID:-${HOMOPAN_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}}"
CWD_TAG="${_CWD:-${HOMOPAN_CWD:-unknown}}"''', 1),
 # jq: add the four --arg bindings (appears twice -> both jq builders)
 ('''      --arg ts "${TIMESTAMP}" --arg tool "${TOOL}" --arg detail "${DETAIL_SAFE}" \\''',
  '''      --arg ts "${TIMESTAMP}" --arg tool "${TOOL}" --arg detail "${DETAIL_SAFE}" \\
      --arg run_id "${RUN_ID_TAG}" --arg agent "${AGENT_TAG}" --arg session "${SESSION_TAG}" --arg cwd "${CWD_TAG}" \\''', 2),
 # jq: with-hash object
 ("'{timestamp: $ts, tool: $tool, detail: $detail, outcome: $outcome, sha256_after: $sha256_after}'",
  "'{timestamp: $ts, run_id: $run_id, agent: $agent, session: $session, cwd: $cwd, tool: $tool, detail: $detail, outcome: $outcome, sha256_after: $sha256_after}'", 1),
 # jq: no-hash object
 ("'{timestamp: $ts, tool: $tool, detail: $detail, outcome: $outcome}'",
  "'{timestamp: $ts, run_id: $run_id, agent: $agent, session: $session, cwd: $cwd, tool: $tool, detail: $detail, outcome: $outcome}'", 1),
 # bash-pure fallback: escape + emit the new fields
 ('''  TS_ESC=$(json_escape "${TIMESTAMP}")''',
  '''  TS_ESC=$(json_escape "${TIMESTAMP}")
  RUN_ESC=$(json_escape "${RUN_ID_TAG}"); AG_ESC=$(json_escape "${AGENT_TAG}"); SE_ESC=$(json_escape "${SESSION_TAG}"); CW_ESC=$(json_escape "${CWD_TAG}")''', 1),
 ('''    LINE=$(printf '{"timestamp":"%s","tool":"%s","detail":"%s","outcome":"%s","sha256_after":"%s"}' \\
      "${TS_ESC}" "${TOOL_ESC}" "${DETAIL_ESC}" "${OUTCOME_ESC}" "${HASH_ESC}")''',
  '''    LINE=$(printf '{"timestamp":"%s","run_id":"%s","agent":"%s","session":"%s","cwd":"%s","tool":"%s","detail":"%s","outcome":"%s","sha256_after":"%s"}' \\
      "${TS_ESC}" "${RUN_ESC}" "${AG_ESC}" "${SE_ESC}" "${CW_ESC}" "${TOOL_ESC}" "${DETAIL_ESC}" "${OUTCOME_ESC}" "${HASH_ESC}")''', 1),
 ('''    LINE=$(printf '{"timestamp":"%s","tool":"%s","detail":"%s","outcome":"%s"}' \\
      "${TS_ESC}" "${TOOL_ESC}" "${DETAIL_ESC}" "${OUTCOME_ESC}")''',
  '''    LINE=$(printf '{"timestamp":"%s","run_id":"%s","agent":"%s","session":"%s","cwd":"%s","tool":"%s","detail":"%s","outcome":"%s"}' \\
      "${TS_ESC}" "${RUN_ESC}" "${AG_ESC}" "${SE_ESC}" "${CW_ESC}" "${TOOL_ESC}" "${DETAIL_ESC}" "${OUTCOME_ESC}")''', 1),
])
print("\nAll protected-file edits applied. Next: bash init.sh && bash verify.sh")
PY
