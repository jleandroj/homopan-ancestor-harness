#!/usr/bin/env bash
# 05_validate_test_hal.sh -- Validate test HAL and extract Anc_HomoPan
set -euo pipefail
source "$(dirname "$0")/config.sh"

script_banner "05 - Validate Test HAL"

acquire_step_lock "05_validate_test_hal"
require_done "04_run_test_cactus"
assert_file_nonempty "${HAL_TEST}" "Test HAL"

# ── halValidate ───────────────────────────────────────────────────────────
log_step "Running halValidate"
VALIDATE_OUT="${QC_DIR}/test_halValidate.txt"
if run_halValidate "${HAL_TEST}" > "${VALIDATE_OUT}" 2>&1; then
  log_ok "halValidate: valid (exit 0)"
  grep -q "File valid" "${VALIDATE_OUT}" || log_warn "halValidate exited 0 but did not print 'File valid'"
else
  rc=$?
  log_error "halValidate failed (exit ${rc}):"
  cat "${VALIDATE_OUT}"
  die "Test HAL is invalid"
fi

# ── halStats ──────────────────────────────────────────────────────────────
log_step "Running halStats"
STATS_OUT="${QC_DIR}/test_halStats.txt"
run_halStats "${HAL_TEST}" > "${STATS_OUT}" 2>&1
log_info "halStats output:"
cat "${STATS_OUT}"

# ── Verify expected genomes ──────────────────────────────────────────────
log_step "Verifying genomes in HAL"
GENOMES_OUT="${QC_DIR}/test_halGenomes.txt"
run_halStats --genomes "${HAL_TEST}" > "${GENOMES_OUT}" 2>&1

for sp in "${SPECIES[@]}"; do
  if grep -qw "${sp}" "${GENOMES_OUT}"; then
    log_ok "Found: ${sp}"
  else
    die "Missing genome in HAL: ${sp}"
  fi
done

for anc in "${ANCESTOR_NODES[@]}"; do
  if grep -qw "${anc}" "${GENOMES_OUT}"; then
    log_ok "Found ancestor: ${anc}"
  else
    die "Missing ancestor in HAL: ${anc}"
  fi
done

# ── Verify tree ───────────────────────────────────────────────────────────
log_step "Checking tree"
TREE_OUT="${QC_DIR}/test_halTree.txt"
run_halStats --tree "${HAL_TEST}" > "${TREE_OUT}" 2>&1
log_info "Tree: $(cat "${TREE_OUT}")"

# ── Extract Anc_HomoPan test FASTA ────────────────────────────────────────
log_step "Extracting Anc_HomoPan test ancestor"
ANC_TEST_FA="${RESULTS_ANCESTORS}/Anc_HomoPan.test.fa"
run_hal2fasta "${HAL_TEST}" Anc_HomoPan > "${ANC_TEST_FA}"
assert_file_nonempty "${ANC_TEST_FA}" "Anc_HomoPan.test.fa"

# Index it
run_samtools faidx "${ANC_TEST_FA}"

ANC_BP=$(awk '{sum+=$2}END{print sum}' "${ANC_TEST_FA}.fai")
log_ok "Anc_HomoPan test: ${ANC_BP} bp"

log_ok "Test HAL validation complete"
mark_done "05_validate_test_hal"
