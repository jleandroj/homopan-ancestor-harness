#!/usr/bin/env bash
# LiteratureAgent -- novelty guard. Any claim of "novel/first/unprecedented" must
# carry a literature-search evidence pointer (paper/db); otherwise the novelty is
# UNSUPPORTED. Cannot browse -> never asserts a finding IS novel, only flags gaps.
source "$(dirname "${BASH_SOURCE[0]}")/lib_verdict.sh"
verdict_init "LiteratureAgent"

CL=""
for c in "${CLAIMS:-}" "${VRUN}/claims.tsv" "${ROOT}/agents/claims.tsv"; do
  [[ -n "$c" && -s "$c" ]] && { CL="$c"; break; }
done
if [[ -z "$CL" ]]; then
  check novelty NOT_TESTED "" "no claims file -> no novelty assertions to check"
  verdict_emit "no claims"
  exit 0
fi

flagged=0; n=0
while IFS=$'\t' read -r claim etype eref; do
  [[ -z "$claim" || "$claim" == \#* ]] && continue
  if grep -qiE 'novel|first (ever|to|report|time|descri|identif)|unprecedented|never (before|seen)|primer[oa]?|nunca antes' <<<"$claim"; then
    n=$((n+1))
    if [[ "${etype,,}" == paper || "${etype,,}" == db ]] && [[ -n "$eref" ]]; then
      check "novelty_${n}" PASS_EXPLORATORY "$eref" "novelty claim cites literature/db: ${claim:0:45}"
    else
      check "novelty_${n}" UNKNOWN "${etype}:${eref}" "NOVELTY claimed without literature evidence -> UNSUPPORTED: ${claim:0:45}"
      flagged=$((flagged+1))
    fi
  fi
done < "$CL"
(( n == 0 )) && check novelty NOT_TESTED "$CL" "no novelty/firstness claims found"
verdict_emit "novelty guard (${flagged} unsupported)"
