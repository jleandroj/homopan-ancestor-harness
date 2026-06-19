#!/usr/bin/env bash
# 01_validate_fastas.sh -- Validate and index the 5 full FASTA genomes
set -euo pipefail
source "$(dirname "$0")/config.sh"

script_banner "01 - Validate Full FASTAs"

require_done "00_check_env"

CHECKSUMS_FILE="${QC_DIR}/genome_checksums.tsv"
> "${CHECKSUMS_FILE}"

for sp in "${SPECIES[@]}"; do
  FA="${GENOMES_DIR}/${sp}.fa"
  FAI="${FA}.fai"

  log_step "Validating ${sp}"

  # Check FASTA exists and is non-empty
  assert_file_nonempty "${FA}" "${sp}.fa"

  # Index if needed
  if [[ ! -f "${FAI}" ]] || [[ "${FA}" -nt "${FAI}" ]]; then
    log_info "Indexing ${sp}.fa"
    run_samtools faidx "${FA}"
  fi
  assert_file_nonempty "${FAI}" "${sp}.fa.fai"

  # Report stats from .fai
  NUM_SEQS=$(wc -l < "${FAI}")
  TOTAL_BP=$(awk '{sum+=$2}END{print sum}' "${FAI}")
  log_ok "${sp}: ${NUM_SEQS} sequences, ${TOTAL_BP} bp"

  # Checksum
  SHA=$(compute_sha256 "${FA}")
  SIZE=$(stat -c %s "${FA}" 2>/dev/null || wc -c < "${FA}")
  printf '%s\t%s\t%s\t%s\t%s\n' "${sp}" "${SHA}" "${SIZE}" "${NUM_SEQS}" "${TOTAL_BP}" \
    >> "${CHECKSUMS_FILE}"
done

log_ok "Checksums written to $(sanitize_path "${CHECKSUMS_FILE}")"
mark_done "01_validate_fastas"
