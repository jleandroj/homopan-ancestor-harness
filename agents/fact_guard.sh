#!/usr/bin/env bash
# FactGuardAgent -- every scientific claim must be backed by evidence: a file, a
# logged command, a paper (DOI/PMID), a database id, or a reproducible result.
# A claim with no/weak/broken evidence => FAIL_EVIDENCE. No claims => NOT_TESTED.
#
# Claims file (TSV): claim_text <TAB> evidence_type <TAB> evidence_ref
#   evidence_type: file | command | paper | db | result | none
# Searched at: $CLAIMS, ${VRUN}/claims.tsv, ${ROOT}/agents/claims.tsv
source "$(dirname "${BASH_SOURCE[0]}")/lib_verdict.sh"
verdict_init "FactGuardAgent"

CL=""
for c in "${CLAIMS:-}" "${VRUN}/claims.tsv" "${ROOT}/agents/claims.tsv"; do
  [[ -n "$c" && -s "$c" ]] && { CL="$c"; break; }
done
if [[ -z "$CL" ]]; then
  check claims NOT_TESTED "" "no claims file -> nothing to guard (no biological claims asserted)"
  verdict_emit "no claims to verify"
  exit 0
fi

AUDIT="${HARNESS_AUDIT_LOG:-${HOME}/.harness_audit.jsonl}"
n=0; bad=0
while IFS=$'\t' read -r claim etype eref; do
  [[ -z "$claim" || "$claim" == \#* ]] && continue
  n=$((n+1)); cid="claim_${n}"
  case "${etype,,}" in
    file|result)
      f="${eref}"; [[ "$f" != /* ]] && f="${ROOT}/${eref}"
      [[ -e "$f" ]] && check "$cid" PASS "$eref" "${claim:0:60}" \
                    || check "$cid" FAIL_EVIDENCE "$eref" "evidence file MISSING: ${claim:0:50}";;
    command)
      if [[ -s "$AUDIT" ]] && grep -Fq "$eref" "$AUDIT" 2>/dev/null; then
        check "$cid" PASS "audit:${eref}" "${claim:0:60}"
      else
        check "$cid" INSUFFICIENT_EVIDENCE "$eref" "command not found in audit log: ${claim:0:50}"
      fi;;
    paper)
      if grep -qE '10\.[0-9]{4,}/|PMID:?[0-9]{5,}' <<<"$eref"; then
        check "$cid" PASS_EXPLORATORY "$eref" "cites DOI/PMID (not auto-verified): ${claim:0:50}"
      else
        check "$cid" FAIL_EVIDENCE "$eref" "paper ref lacks DOI/PMID: ${claim:0:50}"
      fi;;
    db)
      [[ -n "$eref" ]] && check "$cid" PASS_EXPLORATORY "$eref" "db reference: ${claim:0:55}" \
                       || check "$cid" FAIL_EVIDENCE "" "db ref empty: ${claim:0:50}";;
    none|"")
      check "$cid" FAIL_EVIDENCE "" "NO EVIDENCE for claim: ${claim:0:60}"; bad=$((bad+1));;
    *)
      check "$cid" FAIL_EVIDENCE "$eref" "unknown evidence type '${etype}': ${claim:0:50}";;
  esac
done < "$CL"
(( n == 0 )) && check claims NOT_TESTED "$CL" "claims file empty"
verdict_emit "${n} claims checked"
