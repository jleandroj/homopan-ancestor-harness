#!/usr/bin/env bash
# 08_extract_ancestors.sh -- Extract all 4 ancestor FASTAs from full HAL
set -euo pipefail
source "$(dirname "$0")/config.sh"

script_banner "08 - Extract Ancestors"

acquire_step_lock "08_extract_ancestors"
require_done "07_validate_full_hal"
assert_file_nonempty "${HAL_FULL}" "Full HAL"

# Truncate checksums file before appending (prevents duplicates on re-runs)
> "${QC_DIR}/ancestor_checksums.tsv"

EXTRACTED=0

for anc in "${ANCESTOR_NODES[@]}"; do
  FA="${RESULTS_ANCESTORS}/${anc}.fa"
  log_step "Extracting ${anc}"

  run_hal2fasta "${HAL_FULL}" "${anc}" > "${FA}"
  assert_file_nonempty "${FA}" "${anc}.fa"

  # Quality gate (#4): a mostly-N ancestor is degenerate, not a success.
  # Fail-closed above HOMOPAN_MAX_N_FRAC; records the fraction either way.
  NFRAC=$(assert_ancestor_quality "${FA}" "${anc}")

  # Index
  run_samtools faidx "${FA}"

  # Stats
  NUM_SEQS=$(wc -l < "${FA}.fai")
  TOTAL_BP=$(awk '{sum+=$2}END{print sum}' "${FA}.fai")
  log_ok "${anc}: ${NUM_SEQS} sequences, ${TOTAL_BP} bp, N-fraction ${NFRAC}"

  # Checksum (cols: name, sha256, bp, n_fraction)
  SHA=$(compute_sha256 "${FA}")
  echo -e "${anc}\t${SHA}\t${TOTAL_BP}\t${NFRAC}" >> "${QC_DIR}/ancestor_checksums.tsv"

  ((EXTRACTED++)) || true
done

log_ok "Extracted ${EXTRACTED}/${#ANCESTOR_NODES[@]} ancestors to $(sanitize_path "${RESULTS_ANCESTORS}")"
mark_done "08_extract_ancestors"
