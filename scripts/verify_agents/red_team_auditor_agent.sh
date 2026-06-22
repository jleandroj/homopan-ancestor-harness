#!/usr/bin/env bash
# red_team_auditor_agent.sh <ctx_dir>
# Adversary: assume the result is wrong and try to prove it. Looks for stale
# outputs (output older than its inputs), silent errors (exit 0 but empty output),
# and overstated conclusions vs. the actual verdicts. Any solid catch -> a FAIL.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${HERE}/lib_agent.sh"
agent_begin "RedTeamAuditorAgent"; jq="$(agent_jq)"
ctx="${1:?ctx dir}"; caught=0
# 1. stale outputs: any outputs/* older than any inputs/* (mtime)
if [[ -d "${ctx}/inputs" && -d "${ctx}/outputs" ]]; then
  newest_in="$(find "${ctx}/inputs" -type f -printf '%T@\n' 2>/dev/null | sort -nr | head -1)"
  while IFS= read -r o; do
    ot="$(stat -c %Y "$o" 2>/dev/null || echo 0)"
    awk "BEGIN{exit !(${ot} < ${newest_in:-0})}" 2>/dev/null && { agent_finding "STALE output (older than inputs): ${o#${ctx}/}"; caught=1; }
  done < <(find "${ctx}/outputs" -type f 2>/dev/null)
fi
# 2. silent errors: audit action_end with exit 0 but 0 bytes out AND 0 bytes err
audit="${ctx}/audit.jsonl"; [[ -f "${audit}" ]] || audit="$(ls -t "${ctx}"/_harness/*/audit.jsonl 2>/dev/null | head -1)"
if [[ -n "${audit}" && -f "${audit}" ]]; then
  sil="$("${jq}" -rs '[.[]|select(.type=="action_end" and .exit=="0" and .out_bytes=="0" and .err_bytes=="0")]|length' < "${audit}" 2>/dev/null || echo 0)"
  (( sil > 0 )) && { agent_finding "${sil} action(s) exited 0 with NO output (possible silent no-op/error)"; caught=1; }
fi
# 3. overstated conclusion: a PASS-level claim while reproducibility FAILED
v="${ctx}/verdicts.jsonl"
if [[ -f "${v}" ]]; then
  rep="$("${jq}" -rs 'map(select(.agent=="ReproducibilityAgent"))|last|.status // "ABSENT"' < "${v}" 2>/dev/null)"
  bio="$("${jq}" -rs 'map(select(.agent=="BiologicalInterpretationAgent"))|last|.status // "ABSENT"' < "${v}" 2>/dev/null)"
  [[ "${rep}" == FAIL_* && "${bio}" == "PASS" ]] && { agent_finding "OVERSTATED: biological PASS while reproducibility=${rep}"; caught=1; }
fi
agent_evidence "audit" "red-team checks: stale-output, silent-error, overstated-conclusion"
if (( caught )); then agent_emit FAIL_VALIDATION "red-team found integrity problems (see findings)"
else agent_emit PASS "red-team found no stale outputs, silent errors, or overstated conclusions"; fi
exit $?
