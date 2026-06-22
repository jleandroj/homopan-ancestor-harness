#!/usr/bin/env bash
# fact_guard_agent.sh <ctx_dir>
# Every scientific claim must be backed by evidence. Reads <ctx>/claims.tsv:
#   <claim text>\t<evidence_ref>
# evidence_ref: a path (must exist), or "PMID:..", "DB:..", "cmd:..", "run:..".
# A claim with empty/none evidence -> FAIL_EVIDENCE. Overstated language
# ("novel","proves","confirms","first") demands strong evidence (a path/PMID),
# otherwise it is flagged. No claims.tsv -> NOT_TESTED.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${HERE}/lib_agent.sh"
agent_begin "FactGuardAgent"
ctx="${1:?ctx dir}"; f="${ctx}/claims.tsv"
[[ -f "${f}" ]] || { agent_emit NOT_TESTED "no claims.tsv: no claims to guard"; exit $?; }
unbacked=0; overstated=0; n=0
while IFS=$'\t' read -r claim ev; do
  [[ -z "${claim}" || "${claim}" == \#* ]] && continue
  n=$((n+1)); ev="${ev//[[:space:]]/}"
  local_ok=1
  if [[ -z "${ev}" || "${ev}" == "none" || "${ev}" == "NA" ]]; then
    agent_finding "UNBACKED: ${claim}"; unbacked=1; local_ok=0
  elif [[ "${ev}" != PMID:* && "${ev}" != DB:* && "${ev}" != cmd:* && "${ev}" != run:* ]]; then
    # treat as a path (relative to ctx)
    p="${ev}"; [[ "${p}" != /* ]] && p="${ctx}/${p}"
    [[ -e "${p}" ]] || { agent_finding "evidence file missing for claim (${claim}): ${ev}"; unbacked=1; local_ok=0; }
  fi
  # overstated language needs a strong ref (path or PMID/DB), never just cmd/run
  if grep -qiE '\b(novel|proves|confirms|first|unprecedented|definitiv)' <<<"${claim}"; then
    if [[ "${ev}" == cmd:* || "${ev}" == run:* || -z "${ev}" ]]; then
      agent_finding "OVERSTATED w/o literature/db evidence: ${claim}"; overstated=1
    fi
  fi
  (( local_ok )) && agent_evidence "claim" "backed: ${claim%% *}... -> ${ev}"
done < "${f}"
(( n == 0 )) && { agent_emit NOT_TESTED "claims.tsv empty"; exit $?; }
if (( unbacked )); then agent_emit FAIL_EVIDENCE "${n} claim(s); some have NO backing evidence"
elif (( overstated )); then agent_emit INSUFFICIENT_EVIDENCE "claims backed but overstated language lacks literature/db proof"
else agent_emit PASS "all ${n} claim(s) backed by checkable evidence"; fi
exit $?
