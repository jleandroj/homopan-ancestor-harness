#!/usr/bin/env bash
# 07_validate_full_hal.sh -- Validate full HAL, verify all 4 ancestor nodes
set -euo pipefail
source "$(dirname "$0")/config.sh"

script_banner "07 - Validate Full HAL"

require_done "06_run_full_cactus"
assert_file_nonempty "${HAL_FULL}" "Full HAL"

# ── halValidate ───────────────────────────────────────────────────────────
log_step "Running halValidate"
VALIDATE_OUT="${QC_DIR}/full_halValidate.txt"
if run_halValidate "${HAL_FULL}" > "${VALIDATE_OUT}" 2>&1; then
  log_ok "halValidate: valid (exit 0)"
  grep -q "File valid" "${VALIDATE_OUT}" || log_warn "halValidate exited 0 but did not print 'File valid'"
else
  rc=$?
  log_error "halValidate failed (exit ${rc}):"
  cat "${VALIDATE_OUT}"
  die "Full HAL is invalid"
fi

# ── halStats ──────────────────────────────────────────────────────────────
log_step "Running halStats"
STATS_OUT="${QC_DIR}/full_halStats.txt"
run_halStats "${HAL_FULL}" > "${STATS_OUT}" 2>&1
log_info "halStats output:"
cat "${STATS_OUT}"

# ── Verify expected genomes ──────────────────────────────────────────────
log_step "Verifying genomes in full HAL"
GENOMES_OUT="${QC_DIR}/full_halGenomes.txt"
run_halStats --genomes "${HAL_FULL}" > "${GENOMES_OUT}" 2>&1

for sp in "${SPECIES[@]}"; do
  if grep -qw "${sp}" "${GENOMES_OUT}"; then
    log_ok "Found species: ${sp}"
  else
    die "Missing genome in full HAL: ${sp}"
  fi
done

for anc in "${ANCESTOR_NODES[@]}"; do
  if grep -qw "${anc}" "${GENOMES_OUT}"; then
    log_ok "Found ancestor: ${anc}"
  else
    die "Missing ancestor in full HAL: ${anc}"
  fi
done

# ── Verify tree ───────────────────────────────────────────────────────────
log_step "Checking tree"
TREE_OUT="${QC_DIR}/full_halTree.txt"
run_halStats --tree "${HAL_FULL}" > "${TREE_OUT}" 2>&1
log_info "Tree: $(cat "${TREE_OUT}")"

# ── Per-genome stats ──────────────────────────────────────────────────────
log_step "Per-genome lengths"
GENOME_SIZES="${QC_DIR}/full_halGenomeSizes.txt"
> "${GENOME_SIZES}"
while IFS= read -r genome; do
  LEN=$(run_halStats --genomeLength "${genome}" "${HAL_FULL}" 2>/dev/null || echo "N/A")
  echo -e "${genome}\t${LEN}" >> "${GENOME_SIZES}"
  log_info "  ${genome}: ${LEN} bp"
done < <(run_halStats --genomes "${HAL_FULL}" | tr ',' '\n' | sed 's/^ //')

# ── HAL file size ─────────────────────────────────────────────────────────
HAL_SIZE=$(du -h "${HAL_FULL}" | cut -f1)
log_info "Full HAL size: ${HAL_SIZE}"

# ── Checksum ──────────────────────────────────────────────────────────────
log_step "Computing HAL checksum"
SHA=$(compute_sha256 "${HAL_FULL}")
echo "${SHA}  primates.full.hal" > "${QC_DIR}/full_hal_sha256.txt"
log_ok "SHA256: ${SHA}"

log_ok "Full HAL validation complete"
mark_done "07_validate_full_hal"
