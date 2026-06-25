#!/usr/bin/env bash
# ledger_audit.sh [ledger.jsonl]
# Closes lie-vector #3 (cherry-picking): scans the cross-run ledger and FLAGS any
# group of runs that share the same inputs_hash -- i.e. the same analysis was run
# more than once, so a single reported run may have hidden siblings. It does not
# accuse; it makes selection visible so a human can ask "where are the other runs?".
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ledger="${1:-${HOMOPAN_LEDGER:-$(cd "${HERE}/../.." && pwd)/runs/_ledger.jsonl}}"
jq=jq; command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
[[ -f "${ledger}" ]] || { echo "no ledger: ${ledger} (no runs recorded yet)"; exit 0; }
# group by inputs_hash (ignoring 'none'); report groups with >1 run.
report="$("${jq}" -rs '
  group_by(.inputs_hash)
  | map(select(.[0].inputs_hash != "none" and length > 1))
  | map({inputs_hash: .[0].inputs_hash, runs: length,
         finals: (map(.final) | group_by(.) | map({(.[0]):length}) | add)})' < "${ledger}")"
groups="$("${jq}" 'length' <<<"${report}")"
if [[ "${groups}" -gt 0 ]]; then
  echo "CHERRY-PICK SMELL: ${groups} input-set(s) were analysed by MULTIPLE runs:"
  "${jq}" -r '.[] | "  inputs \(.inputs_hash): \(.runs) runs, outcomes \(.finals)"' <<<"${report}"
  echo "  -> If only one run was reported, ask for the others before trusting the result."
  exit 1
fi
echo "ledger clean: no input-set was run more than once (no cherry-pick smell)"
exit 0
