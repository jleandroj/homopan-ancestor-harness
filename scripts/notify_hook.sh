#!/usr/bin/env bash
# notify_hook.sh -- ITER 9: PostToolUse/PreToolUse notification hook for Claude
# Code. Fires a desktop pop-up + appends to logs/activity.feed for EVERY tool
# call (so the user is aware of anything the agent/machine does in real time).
# Fail-open: never blocks a tool (always exit 0).
#
# Wire in .claude/settings.json (user applies; see OPERATIONS.md):
#   "PreToolUse":  [{ "matcher":"*","hooks":[{"type":"command","command":"bash .claude/notify_hook.sh pre"}] }]
#   "PostToolUse": [{ "matcher":"*","hooks":[{"type":"command","command":"bash .claude/notify_hook.sh post"}] }]
set -uo pipefail
PHASE="${1:-post}"
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SD}/.." 2>/dev/null && pwd)"; [[ -z "${ROOT}" ]] && ROOT="$(pwd)"
FEED="${ROOT}/logs/activity.feed"; mkdir -p "${ROOT}/logs" 2>/dev/null || true
IN="$(cat 2>/dev/null || true)"

field(){ # <jsonkey>  (jq if present, else grep)
  if command -v jq >/dev/null 2>&1; then printf '%s' "$IN" | jq -r "$1 // empty" 2>/dev/null; else
    printf '%s' "$IN" | grep -oE "\"${1##*.}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*: *"//;s/"$//'; fi; }

TOOL="$(field '.tool_name')"; TOOL="${TOOL:-?}"
DETAIL=""
case "${TOOL}" in
  Bash) DETAIL="$(field '.tool_input.command')";;
  Write|Edit|Read|NotebookEdit) DETAIL="$(field '.tool_input.file_path')";;
  Task|Agent) DETAIL="$(field '.tool_input.subagent_type') $(field '.tool_input.description')";;
  WebFetch|WebSearch) DETAIL="$(field '.tool_input.url')$(field '.tool_input.query')";;
esac
DETAIL="${DETAIL//$'\n'/ }"; DETAIL="${DETAIL:0:90}"

# only pop a desktop notification for meaningful events (avoid Read/Grep spam)
notify=0
case "${TOOL}" in Bash|Write|Edit|NotebookEdit|Task|Agent|WebFetch|WebSearch) notify=1;; esac
# always-notify (critical) signals regardless of tool
crit=0
grep -Eq '\.ssh|\.aws|id_rsa|credentials|/etc/shadow|rm[[:space:]]+-[a-zA-Z]*[rf]|curl|wget|/dev/tcp|socket\.' <<<"${DETAIL}" && crit=1

printf '%s [%s] %s %s\n' "$(date '+%H:%M:%S')" "${PHASE}" "${TOOL}" "${DETAIL}" >> "${FEED}" 2>/dev/null || true
if [[ "${PHASE}" == "pre" && ( "$notify" == 1 || "$crit" == 1 ) ]] \
   && command -v notify-send >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
  u=normal; [[ "$crit" == 1 ]] && u=critical
  DISPLAY="${DISPLAY}" notify-send -u "$u" "agente: ${TOOL}" "${DETAIL:-（sin detalle）}" >/dev/null 2>&1 || true
fi
exit 0
