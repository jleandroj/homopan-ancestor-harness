#!/usr/bin/env bash
# 06_run_full_cactus_slurm.sh -- SLURM variant for full Cactus run
# Submit with: sbatch scripts/06_run_full_cactus_slurm.sh
#
# NOTE: SLURM is not currently configured on this machine.
#       This script is a template for future HPC use.
#
#SBATCH --job-name=HomoPan_Cactus
#SBATCH --cpus-per-task=20
#SBATCH --mem=128G
#SBATCH --partition=normal
#SBATCH --time=48:00:00
#SBATCH --output=logs/06_run_full_cactus_slurm.%j.out
#SBATCH --error=logs/06_run_full_cactus_slurm.%j.err

set -euo pipefail
source "$(dirname "$0")/config.sh"

script_banner "06 - Run Full Cactus (SLURM)"

require_done "03_make_seqfiles"
[[ -f "${SEQFILE_FULL}" ]] || die "Full seqfile not found: $(sanitize_path "${SEQFILE_FULL}")"
run_preflight "${SEQFILE_FULL}"

LOGFILE="${LOGS_DIR}/06_run_full_cactus_slurm.$(date +%Y%m%d_%H%M%S).log"

# ── Clean previous jobstore ───────────────────────────────────────────────
if [[ -d "${JS_FULL}" ]]; then
  log_warn "Removing old full jobstore"
  rm -rf "${JS_FULL}"
fi

if [[ -f "${HAL_FULL}" ]]; then
  log_warn "Removing old full HAL"
  rm -f "${HAL_FULL}"
fi

# ── Run Cactus ────────────────────────────────────────────────────────────
log_step "Running Cactus full alignment via SLURM"
log_info "SLURM Job ID: ${SLURM_JOB_ID:-local}"
log_info "Seqfile: $(sanitize_path "${SEQFILE_FULL}")"
log_info "Output:  $(sanitize_path "${HAL_FULL}")"

START_TIME=$(date +%s)

# NOTE: run_cactus already adds `cactus --binariesMode local`; do not repeat it.
run_cactus \
  "${JS_FULL}" \
  "${SEQFILE_FULL}" \
  "${HAL_FULL}" \
  --batchSystem single_machine \
  --realTimeLogging true \
  2>&1 | tee "${LOGFILE}"

if (( PIPESTATUS[0] == 124 )); then
  die "Cactus full alignment (SLURM) timed out after ${CACTUS_TIMEOUT:-172800}s"
fi

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
HOURS=$(( ELAPSED / 3600 ))
MINS=$(( (ELAPSED % 3600) / 60 ))

log_info "Elapsed: ${HOURS}h ${MINS}m"

assert_file_nonempty "${HAL_FULL}" "Full HAL"

log_ok "Cactus full alignment complete (SLURM)"
mark_done "06_run_full_cactus"
