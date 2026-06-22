#!/usr/bin/env bash
# InputIntegrityAgent -- validates inputs BEFORE analysis: FASTA exist + indexed,
# accessions/species, and (when required) GTF/HAL/MAF/VCF/counts. Absent-but-
# not-required inputs are reported NOT_TESTED (honest), never silently assumed.
source "$(dirname "${BASH_SOURCE[0]}")/lib_verdict.sh"
verdict_init "InputIntegrityAgent"
G="${ROOT}/genomes"; CG="${ROOT}/cgv_genomes"

nfa=0
for fa in "${G}"/*.fa "${CG}"/*.fa; do
  [[ -e "$fa" ]] || continue
  if [[ -s "$fa" ]]; then
    nfa=$((nfa+1))
    [[ -s "${fa}.fai" ]] || check "faidx_$(basename "$fa")" INSUFFICIENT_EVIDENCE "$fa" "FASTA present but NOT indexed (.fai missing)"
  fi
done
(( nfa > 0 )) && check fasta_present PASS "${G}/,${CG}/" "${nfa} FASTA present" \
              || check fasta_present FAIL_EVIDENCE "" "no FASTA inputs found"

[[ -s "${ROOT}/accessions.tsv" ]] && check accessions PASS "accessions.tsv" "$(grep -c . "${ROOT}/accessions.tsv") species mapped" \
                                  || check accessions NOT_TESTED "" "no accessions.tsv"

# optional inputs: report NOT_TESTED when not present (do not assume)
shopt -s nullglob
for kind in "GTF:*.gtf:*.gff" "HAL:results/**/*.hal" "MAF:*.maf" "VCF:*.vcf:*.vcf.gz" "COUNTS:*counts*.tsv:*counts*.csv"; do
  label="${kind%%:*}"; pats="${kind#*:}"
  found=""
  IFS=':' read -ra ps <<<"$pats"
  for p in "${ps[@]}"; do for f in ${ROOT}/$p; do [[ -e "$f" ]] && { found="$f"; break 2; }; done; done
  [[ -n "$found" ]] && check "input_${label}" PASS "$found" "${label} present" \
                    || check "input_${label}" NOT_TESTED "" "${label} not present (not required for this run)"
done
verdict_emit "input integrity"
