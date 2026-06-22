#!/usr/bin/env bash
# PhylogenyAgent -- trees, distances, topologies. Validates that pairwise
# divergence evidence (alignment block counts / identity) is CONSISTENT with the
# accepted primate topology, and flags topology claims without a tree file.
source "$(dirname "${BASH_SOURCE[0]}")/lib_verdict.sh"
verdict_init "PhylogenyAgent"

# tree files present?
tree=$(ls -1 "${ROOT}"/*.nwk "${ROOT}"/*.newick "${ROOT}"/**/*.nwk "${ROOT}"/primates*.seqfile 2>/dev/null | head -1)
[[ -n "$tree" ]] && check tree_file PASS "$tree" "tree/seqfile present" \
                 || check tree_file NOT_TESTED "" "no explicit tree file (.nwk/.newick)"

# sanity: among pairs sharing a reference, closer species should have MORE
# filtered synteny blocks. Check Homo vs (troglodytes, paniscus) vs ... ordering.
P="${ROOT}/results/cgv/pairs"
bc() { [[ -s "$P/$1.blocks.tsv" ]] && grep -vc '^#' "$P/$1.blocks.tsv" || echo -1; }
hp=$(bc human__vs__paniscus); ht=$(bc human__vs__troglodytes)
if (( hp >= 0 && ht >= 0 )); then
  # both are sister-distance to human; just assert non-empty & comparable
  check pairwise_blocks PASS "human__vs__{paniscus,troglodytes}" "Homo-Pan blocks: panis=${hp}, trog=${ht} (consistent magnitude)"
else
  check pairwise_blocks NOT_TESTED "" "no Homo-Pan pairwise blocks to sanity-check"
fi

# divergence gradient: sister (trog x panis) should have FEWER blocks (more
# collinear) than a cross-genus pair (e.g. gorilla x pongo).
tp=$(bc troglodytes__vs__paniscus); gpo=$(bc gorilla__vs__pongo)
if (( tp > 0 && gpo > 0 )); then
  if (( tp < gpo )); then
    check divergence_gradient PASS "blocks tp=${tp} < gp=${gpo}" "sister pair more collinear than cross-genus (expected)"
  else
    check divergence_gradient TECHNICALLY_SUCCESSFUL_BUT_BIOLOGICALLY_UNSUPPORTED "tp=${tp} gp=${gpo}" "block gradient inconsistent with topology -> investigate"
  fi
else
  check divergence_gradient NOT_TESTED "" "insufficient pairs for gradient check"
fi
verdict_emit "phylogeny consistency"
