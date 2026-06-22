#!/usr/bin/env bash
# AncestorValidationAgent -- reconstructed ancestors are INFERRED, never observed.
# Always emits the "inferred_not_observed" guard; validates quality (N-fraction)
# reusing the harness gate; marks degenerate reconstructions FAIL_VALIDATION.
source "$(dirname "${BASH_SOURCE[0]}")/lib_verdict.sh"
verdict_init "AncestorValidationAgent"

ANC=$(ls -1 "${ROOT}"/results/ancestors/*.fa "${ROOT}"/runs/*/results/ancestors/*.fa 2>/dev/null)
if [[ -z "$ANC" ]]; then
  check ancestors_present NOT_TESTED "" "no reconstructed ancestors in this run"
  check inferred_not_observed PASS "policy" "RULE active: any future ancestor is INFERRED, never an observed genome"
  verdict_emit "no ancestors to validate"
  exit 0
fi

# enforce the cardinal rule regardless of quality
check inferred_not_observed PASS "policy" "ancestors are INFERRED reconstructions, NOT observed genomes (never a tree tip / evidence)"

nfrac() { awk '!/^>/{s=$0; n=gsub(/[Nn]/,"",s); N+=n; T+=length($0)} END{if(T==0)print 1; else printf "%.4f",N/T}' "$1"; }
worst=PASS
while IFS= read -r fa; do
  [[ -s "$fa" ]] || { check "$(basename "$fa")" FAIL_VALIDATION "$fa" "ancestor file empty"; worst=FAIL_VALIDATION; continue; }
  nf=$(nfrac "$fa"); b=$(basename "$fa")
  if awk "BEGIN{exit !(${nf}>0.90)}"; then
    check "$b" FAIL_VALIDATION "$fa" "N-fraction ${nf} >0.90 -> DEGENERATE reconstruction, NOT interpretable"
  elif awk "BEGIN{exit !(${nf}>0.50)}"; then
    check "$b" EXPLORATORY_ONLY "$fa" "N-fraction ${nf} >0.50 -> LOW-CONFIDENCE, exploratory only"
  else
    check "$b" PASS_EXPLORATORY "$fa" "N-fraction ${nf} (acceptable, but still INFERRED)"
  fi
done <<<"$ANC"
verdict_emit "ancestor validation (inferred-only)"
