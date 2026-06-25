#!/usr/bin/env bash
# reproducibility_agent.sh <ctx_dir>
# A result is NOT biological evidence unless reproducible. THIS AGENT DOES NOT
# TRUST A PROVIDED BOOLEAN -- it RECOMPUTES bit-identity itself from two run
# artifacts it can see (closing the "feed me {bit_identical:true}" hole).
#
# <ctx>/repro.json:
#   {"artifact_a":"<path>", "artifact_b":"<path>",   # REQUIRED for a real verdict
#    "tool":"cactus 9.1.2", "seed_supported":false,
#    "identity":0.33, "threshold":0.999,             # optional equivalence (see below)
#    "source":"repro_verify"}                          # who produced it (audited, not trusted)
#
# Verdicts:
#   no repro.json / no artifacts        -> NOT_TESTED (reproducibility was not measured)
#   bare assertion, no artifacts        -> INSUFFICIENT_EVIDENCE (asserted, not measured)
#   artifacts present, sha equal        -> PASS (agent recomputed bit-identity)
#   artifacts differ, no equiv proof    -> FAIL_REPRODUCIBILITY
#   artifacts differ + equiv measured by repro_verify >= threshold -> PASS_EXPLORATORY
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${HERE}/lib_agent.sh"
agent_begin "ReproducibilityAgent"; jq="$(agent_jq)"
ctx="${1:?ctx dir}"; r="${ctx}/repro.json"
[[ -f "${r}" ]] || { agent_emit NOT_TESTED "no repro.json: reproducibility was NOT measured"; exit $?; }

a="$("${jq}" -r '.artifact_a // empty' < "${r}" 2>/dev/null)"
b="$("${jq}" -r '.artifact_b // empty' < "${r}" 2>/dev/null)"
tool="$("${jq}" -r '.tool // "unknown"' < "${r}" 2>/dev/null)"
[[ "$("${jq}" -r '.seed_supported // true' < "${r}")" == "false" ]] && agent_finding "tool ${tool} has no RNG seed -> intrinsically non-deterministic"

# resolve relative to ctx
[[ -n "${a}" && "${a}" != /* ]] && a="${ctx}/${a}"
[[ -n "${b}" && "${b}" != /* ]] && b="${ctx}/${b}"

if [[ -z "${a}" || -z "${b}" || ! -f "${a}" || ! -f "${b}" ]]; then
  # No artifacts to recompute from. A bare boolean is NOT accepted.
  if "${jq}" -e 'has("bit_identical") or has("identity")' < "${r}" >/dev/null 2>&1; then
    agent_finding "repro.json ASSERTS a result but provides no artifacts to recompute -> not trusted"
    agent_emit INSUFFICIENT_EVIDENCE "reproducibility asserted, NOT measured by the harness"
  else
    agent_emit NOT_TESTED "repro.json has no comparable artifacts"
  fi
  exit $?
fi

# Recompute bit-identity OURSELVES (the un-fakeable check).
sa="$(sha256sum "${a}" | cut -d' ' -f1)"; sb="$(sha256sum "${b}" | cut -d' ' -f1)"
agent_evidence "recomputed" "sha(a)=${sa:0:16} sha(b)=${sb:0:16} (computed by the agent, not provided)"
if [[ "${sa}" == "${sb}" ]]; then
  agent_emit PASS "bit-identical across two runs (agent-recomputed) -> reproducible"
  exit $?
fi

# Not bit-identical. Only accept equivalence if it was MEASURED by repro_verify
# (source marker) AND identity >= threshold; otherwise it is a failure.
id="$("${jq}" -r '.identity // empty' < "${r}" 2>/dev/null)"
thr="$("${jq}" -r '.threshold // 0.999' < "${r}" 2>/dev/null)"
src="$("${jq}" -r '.source // "asserted"' < "${r}" 2>/dev/null)"
agent_finding "artifacts DIFFER: a!=b (agent-recomputed)"
if [[ "${src}" == "repro_verify" && -n "${id}" ]] && awk "BEGIN{exit !(${id} >= ${thr})}" 2>/dev/null; then
  agent_evidence "equivalence" "measured by repro_verify: identity ${id} >= ${thr}"
  agent_emit PASS_EXPLORATORY "not bit-identical but measured-equivalent (identity ${id} >= ${thr}); exploratory only"
else
  agent_emit FAIL_REPRODUCIBILITY "runs diverge and no measured equivalence -> NOT biological evidence"
fi
exit $?
