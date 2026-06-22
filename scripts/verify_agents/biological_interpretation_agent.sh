#!/usr/bin/env bash
# biological_interpretation_agent.sh <ctx_dir>
# Translates technical results to biology ONLY if the evidence gates passed. It
# reads the verdicts collected so far (<ctx>/verdicts.jsonl) and REFUSES to
# interpret if FactGuard/Provenance/Reproducibility/InputIntegrity did not pass.
# This is the firewall against "technically successful but biologically unsupported".
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${HERE}/lib_agent.sh"
agent_begin "BiologicalInterpretationAgent"; jq="$(agent_jq)"
ctx="${1:?ctx dir}"; v="${ctx}/verdicts.jsonl"
# Nothing to interpret? Then there is nothing to fail on -> honest NOT_TESTED.
[[ -f "${ctx}/claims.tsv" ]] || { agent_emit NOT_TESTED "no claims to interpret"; exit $?; }
[[ -f "${v}" ]] || { agent_emit INSUFFICIENT_EVIDENCE "no upstream verdicts: cannot justify interpretation"; exit $?; }
gate_status() { "${jq}" -rs --arg a "$1" 'map(select(.agent==$a))|last|.status // "ABSENT"' < "${v}" 2>/dev/null; }
blockers=()
for a in FactGuardAgent ProvenanceAgent InputIntegrityAgent; do
  st="$(gate_status "$a")"
  case "${st}" in PASS|PASS_EXPLORATORY|NOT_TESTED) agent_evidence "gate" "${a}=${st}";;
    *) blockers+=("${a}=${st}"); agent_finding "interpretation blocked: ${a}=${st}";; esac
done
rep="$(gate_status ReproducibilityAgent)"
[[ "${rep}" == FAIL_* ]] && { blockers+=("ReproducibilityAgent=${rep}"); agent_finding "result not reproducible -> NOT biological evidence"; }
if (( ${#blockers[@]} )); then
  agent_emit FAIL_EVIDENCE "biological interpretation withheld: upstream gates failed"
elif [[ "${rep}" == "PASS" ]]; then
  agent_emit PASS "interpretation permitted: evidence + reproducibility gates passed"
else
  agent_emit PASS_EXPLORATORY "interpretation permitted as EXPLORATORY only (repro=${rep}); not confirmatory"
fi
exit $?
