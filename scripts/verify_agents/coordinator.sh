#!/usr/bin/env bash
# coordinator.sh <ctx_dir>
# Orchestrates every verification agent, collects their verdicts, and produces a
# final decision object. CORE RULE: a final biological PASS is allowed ONLY if
# FactGuard, Provenance, and Reproducibility all PASS (and no hard failure
# elsewhere). Anything weaker is downgraded to PASS_EXPLORATORY or UNKNOWN, and
# any hard failure dominates. Execution is never treated as truth.
#
# Final status in: PASS PASS_EXPLORATORY FAIL_TECHNICAL FAIL_REPRODUCIBILITY
#                  FAIL_EVIDENCE FAIL_SECURITY UNKNOWN
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${HERE}/lib_agent.sh"
jq="$(agent_jq)"
ctx="${1:?usage: coordinator.sh <ctx_dir>}"
V="${ctx}/verdicts.jsonl"; : > "${V}"

# Dependency order. Interpretation + red-team run last (they read prior verdicts).
AGENTS=(security_agent input_integrity_agent provenance_agent reproducibility_agent
        phylogeny_agent ancestor_validation_agent statistics_agent fact_guard_agent
        literature_agent biological_interpretation_agent red_team_auditor_agent)

echo "CoordinatorAgent: running ${#AGENTS[@]} verification agents on ${ctx}" >&2
for a in "${AGENTS[@]}"; do
  # capture the agent's single-line verdict; never let one agent abort the run
  verdict="$(bash "${HERE}/${a}.sh" "${ctx}" 2>/dev/null | tail -1)"
  [[ -z "${verdict}" ]] && verdict="$("${jq}" -cn --arg a "${a}" '{agent:$a,status:"UNKNOWN",summary:"agent produced no verdict",evidence:[],findings:["no output"]}')"
  printf '%s\n' "${verdict}" >> "${V}"
  printf '  %-34s %s\n' "${a}" "$("${jq}" -r '.status' <<<"${verdict}" 2>/dev/null)" >&2
done

st() { "${jq}" -rs --arg a "$1" 'map(select(.agent==$a))|last|.status // "ABSENT"' < "${V}"; }
any() { "${jq}" -rs --arg s "$1" 'any(.[]; .status==$s)' < "${V}"; }   # true/false

FG="$(st FactGuardAgent)"; PV="$(st ProvenanceAgent)"; RP="$(st ReproducibilityAgent)"

# Hard failures dominate, worst first.
if [[ "$(any FAIL_SECURITY)" == "true" ]];        then final="FAIL_SECURITY"
elif [[ "$(any FAIL_REPRODUCIBILITY)" == "true" ]]; then final="FAIL_REPRODUCIBILITY"
elif [[ "$(any FAIL_EVIDENCE)" == "true" ]];      then final="FAIL_EVIDENCE"
elif [[ "$(any FAIL_TECHNICAL)" == "true" || "$(any FAIL_VALIDATION)" == "true" ]]; then final="FAIL_TECHNICAL"
else
  # No hard failure. A full PASS REQUIRES the three mandatory gates to PASS.
  if [[ "${FG}" == "PASS" && "${PV}" == "PASS" && "${RP}" == "PASS" ]] \
     && [[ "$(any PASS_EXPLORATORY)" == "false" ]] && [[ "$(any UNKNOWN)" == "false" ]] \
     && [[ "$(any INSUFFICIENT_EVIDENCE)" == "false" ]]; then
    final="PASS"
  elif [[ "${FG}" != "FAIL_EVIDENCE" && "${PV}" != "INSUFFICIENT_EVIDENCE" ]] \
       && [[ "$(any PASS)" == "true" || "$(any PASS_EXPLORATORY)" == "true" ]]; then
    final="PASS_EXPLORATORY"
  else
    final="UNKNOWN"
  fi
fi

reasons="$("${jq}" -rs '[.[]|select(.findings|length>0)|"\(.agent): \(.findings|join("; "))"]' < "${V}")"
"${jq}" -n --arg final "${final}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg fg "${FG}" --arg pv "${PV}" --arg rp "${RP}" \
  --slurpfile verdicts "${V}" --argjson reasons "${reasons}" \
  '{final_status:$final, decided_at:$ts,
    mandatory_gates:{FactGuard:$fg, Provenance:$pv, Reproducibility:$rp},
    rule:"PASS requires FactGuard+Provenance+Reproducibility=PASS and no hard failure; else downgraded.",
    reasons:$reasons, verdicts:$verdicts}' > "${ctx}/decision.json" 2>/dev/null

# Gap #3: append to the cross-run ledger so cherry-picking (run many, show one)
# becomes auditable. inputs_hash groups sibling runs over the same inputs.
ledger="${HOMOPAN_LEDGER:-$(cd "${HERE}/../.." && pwd)/runs/_ledger.jsonl}"
mkdir -p "$(dirname "${ledger}")" 2>/dev/null || true
ih="none"; [[ -f "${ctx}/inputs.tsv" ]] && ih="$(sha256sum "${ctx}/inputs.tsv" 2>/dev/null | cut -c1-16)"
"${jq}" -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ctx "${ctx}" --arg final "${final}" --arg ih "${ih}" \
  '{ts:$ts, ctx:$ctx, final:$final, inputs_hash:$ih}' >> "${ledger}" 2>/dev/null || true

echo "CoordinatorAgent: FINAL = ${final}" >&2
echo "${final}"
case "${final}" in PASS|PASS_EXPLORATORY) exit 0 ;; *) exit 1 ;; esac
