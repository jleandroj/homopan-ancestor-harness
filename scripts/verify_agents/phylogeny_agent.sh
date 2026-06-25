#!/usr/bin/env bash
# phylogeny_agent.sh <ctx_dir>
# Sanity for trees / distances / HAL. Reads <ctx>/tree.nwk and/or <ctx>/hal.txt.
# Cheap structural checks only (balanced parens, >=3 taxa, no zero/neg branch sums
# claimed). Cannot judge biological correctness -> best verdict PASS_EXPLORATORY.
# No tree -> NOT_TESTED.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${HERE}/lib_agent.sh"
agent_begin "PhylogenyAgent"
ctx="${1:?ctx dir}"; t="${ctx}/tree.nwk"
[[ -f "${t}" ]] || { agent_emit NOT_TESTED "no tree.nwk"; exit $?; }
nwk="$(tr -d '[:space:]' < "${t}")"
op="$(tr -cd '(' <<<"${nwk}" | wc -c)"; cp="$(tr -cd ')' <<<"${nwk}" | wc -c)"
taxa="$(grep -oE '[A-Za-z0-9_]+' <<<"${nwk}" | grep -viE '^[0-9.]+$' | sort -u | wc -l)"
ok=1
[[ "${op}" == "${cp}" ]] || { agent_finding "unbalanced parentheses (${op} vs ${cp})"; ok=0; }
[[ "${nwk}" == *\; ]] || { agent_finding "Newick does not end with ';'"; ok=0; }
(( taxa >= 3 )) || { agent_finding "fewer than 3 taxa (${taxa}) -- not a usable tree"; ok=0; }
agent_evidence "tree" "taxa=${taxa}, parens=${op}/${cp}"
if (( ok )); then agent_emit PASS_EXPLORATORY "tree is structurally valid (topology correctness NOT asserted)"
else agent_emit FAIL_VALIDATION "tree structurally invalid"; fi
exit $?
