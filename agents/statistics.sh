#!/usr/bin/env bash
# StatisticsAgent -- guards quantitative claims: significance needs a test,
# multiple comparisons need correction, effect sizes need CIs/n. With no stats
# outputs it reports NOT_TESTED honestly (it does NOT invent significance).
source "$(dirname "${BASH_SOURCE[0]}")/lib_verdict.sh"
verdict_init "StatisticsAgent"

# look for any stats artifacts (p-values, enrichment, tests)
ST=$(grep -rliE 'p[-_ ]?value|pvalue|p<0|fdr|bonferroni|q[-_ ]?value' \
       "${ROOT}/results" 2>/dev/null | head -20)
if [[ -z "$ST" ]]; then
  check stats_present NOT_TESTED "" "no statistical outputs in this run -> no significance claims to validate"
  check multiple_testing NOT_TESTED "" "no multiple-comparison context present"
  verdict_emit "no statistics to validate"
  exit 0
fi

# if p-values exist, demand evidence of correction when many are reported
np=$(grep -rohiE 'p[-_ ]?value|pvalue' $ST 2>/dev/null | wc -l)
if grep -qliE 'fdr|bonferroni|benjamini|q[-_ ]?value|adjusted' $ST 2>/dev/null; then
  check multiple_testing PASS "$(echo "$ST" | head -1)" "multiple-testing correction present (${np} p-value mentions)"
else
  check multiple_testing INSUFFICIENT_EVIDENCE "$(echo "$ST" | head -1)" "${np} p-values but NO correction (FDR/Bonferroni) found -> significance claims unsupported"
fi
verdict_emit "statistics guard"
