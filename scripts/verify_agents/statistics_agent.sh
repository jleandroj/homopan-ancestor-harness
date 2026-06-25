#!/usr/bin/env bash
# statistics_agent.sh <ctx_dir>
# Guards statistical rigor. Reads <ctx>/stats.json:
#   {"tests":N, "multiple_testing_correction":"BH|bonferroni|none",
#    "n_samples":N, "alpha":0.05, "model":"...", "covariates":[...],
#    "population_stratification_controlled":true|false}
# Flags: many tests w/o correction, tiny n, no stratification control, no model.
# No stats.json -> NOT_TESTED.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${HERE}/lib_agent.sh"
agent_begin "StatisticsAgent"; jq="$(agent_jq)"
ctx="${1:?ctx dir}"; s="${ctx}/stats.json"
[[ -f "${s}" ]] || { agent_emit NOT_TESTED "no stats.json: statistics not declared"; exit $?; }
tests="$("${jq}" -r '.tests // 0' < "${s}")"; corr="$("${jq}" -r '.multiple_testing_correction // "none"' < "${s}")"
nn="$("${jq}" -r '.n_samples // 0' < "${s}")"; strat="$("${jq}" -r '.population_stratification_controlled // false' < "${s}")"
model="$("${jq}" -r '.model // ""' < "${s}")"
bad=0
agent_evidence "stats" "tests=${tests} correction=${corr} n=${nn} model='${model}' stratification=${strat}"
(( tests > 1 )) && [[ "${corr}" == "none" ]] && { agent_finding "${tests} tests with NO multiple-testing correction"; bad=1; }
awk "BEGIN{exit !(${nn} < 5)}" 2>/dev/null && { agent_finding "tiny sample size (n=${nn}) -> overfitting/underpowered risk"; bad=1; }
[[ -z "${model}" ]] && agent_finding "no statistical model declared"
[[ "${strat}" == "false" ]] && agent_finding "population stratification NOT controlled (confounding risk)"
if (( bad )); then agent_emit FAIL_VALIDATION "statistical issues that can produce false positives"
elif [[ -z "${model}" || "${strat}" == "false" ]]; then agent_emit INSUFFICIENT_EVIDENCE "statistics declared but rigor incomplete"
else agent_emit PASS "statistics: correction, sample size, model, stratification declared OK"; fi
exit $?
