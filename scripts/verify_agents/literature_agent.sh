#!/usr/bin/env bash
# literature_agent.sh <ctx_dir>
# "novel" / "first" claims require a search record. Reads <ctx>/claims.tsv and a
# <ctx>/literature.tsv (claim_substr\tsearch_ref) listing searches actually done.
# No-egress harness: it cannot search the web, so absent a search record it must
# say NOT_TESTED -- and it FAILS any claim of novelty lacking a search record.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${HERE}/lib_agent.sh"
agent_begin "LiteratureAgent"
ctx="${1:?ctx dir}"; claims="${ctx}/claims.tsv"; lit="${ctx}/literature.tsv"
[[ -f "${claims}" ]] || { agent_emit NOT_TESTED "no claims.tsv"; exit $?; }
novel=(); while IFS=$'\t' read -r claim ev; do
  [[ -z "${claim}" || "${claim}" == \#* ]] && continue
  grep -qiE '\b(novel|first|unprecedented|never (before )?reported)\b' <<<"${claim}" && novel+=("${claim}")
done < "${claims}"
(( ${#novel[@]} )) || { agent_emit NOT_TESTED "no novelty claims to check (no web access in this harness)"; exit $?; }
unproven=0
for c in "${novel[@]}"; do
  if [[ -f "${lit}" ]] && grep -qiF "${c:0:20}" "${lit}" 2>/dev/null; then
    agent_evidence "search" "novelty search recorded for: ${c:0:40}..."
  else
    agent_finding "NOVELTY claim without a recorded literature search: ${c}"; unproven=1
  fi
done
if (( unproven )); then agent_emit FAIL_EVIDENCE "novelty asserted without a literature search record"
else agent_emit PASS_EXPLORATORY "novelty claims have search records (depth not auto-verifiable here)"; fi
exit $?
