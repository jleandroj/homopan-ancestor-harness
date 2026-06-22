#!/usr/bin/env bash
# ReportAgent -- renders the human-facing verification report from the verdicts +
# decision.json of THIS run. Reports honestly: leads with what is NOT supported.
# Writes ${VRUN}/REPORT.md ; prints its path. Never invents a status.
source "$(dirname "${BASH_SOURCE[0]}")/lib_verdict.sh"

DEC="${VRUN}/decision.json"
OUT="${VRUN}/REPORT.md"
ts="$(date -Iseconds)"
final="UNKNOWN"; bio="false"; reason=""
if [[ -s "$DEC" ]]; then
  final="$(_jq -r '.final_status' "$DEC" 2>/dev/null || echo UNKNOWN)"
  bio="$(_jq -r '.biological_conclusions_allowed' "$DEC" 2>/dev/null || echo false)"
  reason="$(_jq -r '.bio_block_reason' "$DEC" 2>/dev/null || echo '')"
fi

{
  echo "# Verification report"
  echo
  echo "- **Run:** \`${VRUN}\`"
  echo "- **Generated:** ${ts}"
  echo "- **FINAL STATUS:** \`${final}\`"
  echo "- **Biological conclusions allowed:** \`${bio}\`"
  [[ "$bio" == "false" && -n "$reason" && "$reason" != "null" ]] && echo "- **Blocked because:** ${reason}"
  echo
  echo "> Principle: *execution is not truth.* A green run does not make a result"
  echo "> correct. Anything below that is not \`PASS\` is unproven, not false-by-default —"
  echo "> the honest label (UNKNOWN / NOT_TESTED / NOT_REPRODUCIBLE / INSUFFICIENT_EVIDENCE) stands."
  echo
  echo "## Agent verdicts"
  echo
  echo "| Agent | Status | Summary |"
  echo "|---|---|---|"
  for f in "${VDIR}"/*.verdict.json; do
    [[ -s "$f" ]] || continue
    a="$(_jq -r '.agent'   "$f" 2>/dev/null)"
    s="$(_jq -r '.status'  "$f" 2>/dev/null)"
    m="$(_jq -r '.summary' "$f" 2>/dev/null)"
    printf '| %s | `%s` | %s |\n' "$a" "$s" "$m"
  done
  echo
  echo "## Checks needing attention (not PASS)"
  echo
  any=0
  for f in "${VDIR}"/*.verdict.json; do
    [[ -s "$f" ]] || continue
    a="$(_jq -r '.agent' "$f" 2>/dev/null)"
    while IFS=$'\t' read -r name st detail; do
      [[ -z "$name" || "$st" == PASS ]] && continue
      printf -- '- **%s / %s** — `%s`: %s\n' "$a" "$name" "$st" "$detail"; any=1
    done < <(_jq -r '.checks[] | [.name,.status,.detail] | @tsv' "$f" 2>/dev/null)
  done
  (( any == 0 )) && echo "_None — every check passed._"
  echo
  echo "## Evidence ledger"
  echo
  if [[ -s "$LEDGER" ]]; then
    echo "Append-only ledger: \`${LEDGER}\` ($(wc -l <"$LEDGER") entries)."
  else
    echo "_No evidence ledger recorded._"
  fi
} > "$OUT"

echo "[ReportAgent] wrote ${OUT}" >&2
echo "$OUT"
