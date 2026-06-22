#!/usr/bin/env bash
# RedTeamAgent -- assumes BAD FAITH of the pipeline/agent. Hunts the failure modes
# that masquerade as success: empty results sold as findings, outputs older than
# their inputs (stale), commands that exited non-zero but were reported ok, and
# overstated language ("proves", "confirms", "definitively") in asserted claims.
source "$(dirname "${BASH_SOURCE[0]}")/lib_verdict.sh"
verdict_init "RedTeamAgent"

# 1) zero-byte / header-only result files presented in results/
empty=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if [[ ! -s "$f" ]] || (( $(grep -vc '^#' "$f" 2>/dev/null || echo 0) == 0 )); then
    empty=$((empty+1))
  fi
done < <(ls -1 "${ROOT}"/results/cgv/pairs/*.blocks.tsv 2>/dev/null)
(( empty > 0 )) && check empty_results FAIL_VALIDATION "results/cgv/pairs" "${empty} result file(s) empty/header-only but presented as output" \
              || check empty_results PASS "results/cgv/pairs" "no empty-result-sold-as-success detected"

# 2) audit log: any action that exited non-zero but was flagged ok:true
AUDIT="${HARNESS_AUDIT_LOG:-${HOME}/.harness_audit.jsonl}"
if [[ -s "$AUDIT" ]]; then
  liars=$(grep -E '"ok":true' "$AUDIT" 2>/dev/null | grep -Ec '"exit":[1-9]' || echo 0)
  (( liars > 0 )) && check exit_consistency FAIL_TECHNICAL "$AUDIT" "${liars} action(s) exit!=0 but ok:true (success-lie)" \
                || check exit_consistency PASS "$AUDIT" "exit codes consistent with ok flags"
else
  check exit_consistency NOT_TESTED "" "no audit log to attack"
fi

# 3) stale outputs: a results file older than the newest input genome
newest_in=$(ls -1t "${ROOT}"/genomes/*.fa "${ROOT}"/data/*.fa 2>/dev/null | head -1)
newest_out=$(ls -1t "${ROOT}"/results/cgv/pairs/*.blocks.tsv 2>/dev/null | head -1)
if [[ -n "$newest_in" && -n "$newest_out" ]]; then
  [[ "$newest_in" -nt "$newest_out" ]] \
    && check staleness INSUFFICIENT_EVIDENCE "$newest_out" "input newer than output -> results may be STALE, re-run before trusting" \
    || check staleness PASS "$newest_out" "outputs newer than inputs"
else
  check staleness NOT_TESTED "" "cannot compare input/output timestamps"
fi

# 4) overstated language in asserted claims
CL=""; for c in "${CLAIMS:-}" "${VRUN}/claims.tsv" "${ROOT}/agents/claims.tsv"; do
  [[ -n "$c" && -s "$c" ]] && { CL="$c"; break; }; done
if [[ -n "$CL" ]]; then
  ov=$(grep -ciE 'prove[ns]?|confirm(s|ed)?|definitiv|certain|undeniabl|demuestra|confirma|sin duda' "$CL" 2>/dev/null || echo 0)
  (( ov > 0 )) && check overstatement TECHNICALLY_SUCCESSFUL_BUT_BIOLOGICALLY_UNSUPPORTED "$CL" "${ov} claim(s) use absolutist language (prove/confirm/definitive) -> soften to 'consistent with'" \
             || check overstatement PASS "$CL" "no absolutist language in claims"
else
  check overstatement NOT_TESTED "" "no claims file"
fi
verdict_emit "adversarial red-team"
