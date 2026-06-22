#!/usr/bin/env bash
# ancestor_validation_agent.sh <ctx_dir>
# A reconstructed ancestor is NEVER an observed genome. For each <ctx>/ancestors/*.fa
# this agent REQUIRES a sibling <file>.provenance.json that marks it as a
# non-deterministic INFERENCE; it gates on N-fraction; and its BEST possible
# verdict is PASS_EXPLORATORY (inferred, usable for exploration) -- never PASS.
#   - degenerate (N-fraction too high)        -> FAIL_VALIDATION
#   - no provenance / not marked inferred     -> INSUFFICIENT_EVIDENCE
#   - marked inferred + within N gate         -> PASS_EXPLORATORY
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${HERE}/lib_agent.sh"
agent_begin "AncestorValidationAgent"; jq="$(agent_jq)"
ctx="${1:?ctx dir}"; dir="${ctx}/ancestors"
maxN="${HOMOPAN_MAX_N_FRAC:-0.90}"
shopt -s nullglob; fas=( "${dir}"/*.fa "${dir}"/*.fasta )
(( ${#fas[@]} )) || { agent_emit NOT_TESTED "no ancestral FASTAs in ${dir}"; exit $?; }
bad=0; weak=0; n=0
for fa in "${fas[@]}"; do
  n=$((n+1)); b="$(basename "${fa}")"
  bp="$(grep -v '^>' "${fa}" 2>/dev/null | tr -d '\n' | wc -c)"
  nc="$(grep -v '^>' "${fa}" 2>/dev/null | tr -cd 'Nn' | wc -c)"
  nf="$(awk -v n="${nc}" -v b="${bp}" 'BEGIN{ if(b>0) printf "%.4f", n/b; else printf "1" }')"
  if awk "BEGIN{exit !(${nf} > ${maxN})}" 2>/dev/null; then
    agent_finding "DEGENERATE ${b}: N-fraction ${nf} > ${maxN} -> not interpretable"; bad=1; continue
  fi
  prov="${fa}.provenance.json"
  if [[ -f "${prov}" ]] && [[ "$("${jq}" -r '.determinism.reproducible // "x"' < "${prov}" 2>/dev/null)" == "false" ]]; then
    agent_evidence "ancestor" "${b}: ${bp}bp, N=${nf}, marked INFERRED + non-reproducible (provenance present)"
  else
    agent_finding "${b}: missing/incomplete provenance -> cannot confirm it is labelled an inferred, non-observed sequence"; weak=1
  fi
done
if (( bad )); then agent_emit FAIL_VALIDATION "ancestor(s) degenerate / not interpretable"
elif (( weak )); then agent_emit INSUFFICIENT_EVIDENCE "ancestor(s) lack provenance to confirm 'inferred, not observed'"
else agent_emit PASS_EXPLORATORY "${n} ancestor(s): INFERRED, non-deterministic; exploratory use only (NOT observed genomes)"; fi
exit $?
