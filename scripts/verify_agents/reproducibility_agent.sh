#!/usr/bin/env bash
# reproducibility_agent.sh <ctx_dir>
# A result is NOT biological evidence unless reproducible. Reads <ctx>/repro.json:
#   {"measured":true|false, "bit_identical":true|false, "identity":0.33, "threshold":0.999, "tool":"cactus 9.1.2", "seed_supported":false}
# Honest verdicts: not measured -> NOT_TESTED; measured & reproducible -> PASS;
# measured & divergent -> FAIL_REPRODUCIBILITY (never hidden).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${HERE}/lib_agent.sh"
agent_begin "ReproducibilityAgent"; jq="$(agent_jq)"
ctx="${1:?ctx dir}"; r="${ctx}/repro.json"
[[ -f "${r}" ]] || { agent_emit NOT_TESTED "no repro.json: reproducibility was NOT measured"; exit $?; }
measured="$("${jq}" -r '.measured // false' < "${r}" 2>/dev/null)"
[[ "${measured}" == "true" ]] || { agent_emit NOT_TESTED "repro.json present but measured=false"; exit $?; }
bit="$("${jq}" -r '.bit_identical // false' < "${r}" 2>/dev/null)"
id="$("${jq}" -r '.identity // empty' < "${r}" 2>/dev/null)"
thr="$("${jq}" -r '.threshold // 0.999' < "${r}" 2>/dev/null)"
tool="$("${jq}" -r '.tool // "unknown"' < "${r}" 2>/dev/null)"
agent_evidence "repro" "tool=${tool} bit_identical=${bit} identity=${id:-NA} threshold=${thr}"
if [[ "${bit}" == "true" ]]; then
  agent_emit PASS "bit-identical across runs -> reproducible"
elif [[ -n "${id}" ]] && awk "BEGIN{exit !(${id} >= ${thr})}" 2>/dev/null; then
  agent_emit PASS_EXPLORATORY "not bit-identical but equivalent (identity ${id} >= ${thr})"
else
  [[ "$("${jq}" -r '.seed_supported // true' < "${r}")" == "false" ]] && agent_finding "tool has no RNG seed (${tool}); runs are intrinsically non-deterministic"
  agent_finding "identity ${id:-NA} < ${thr}: results NOT reproducible"
  agent_emit FAIL_REPRODUCIBILITY "runs diverge; result is NOT biological evidence"
fi
exit $?
