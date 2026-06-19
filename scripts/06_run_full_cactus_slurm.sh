#!/usr/bin/env bash
# 06_run_full_cactus_slurm.sh -- SLURM variant for full Cactus run
# Submit with: sbatch scripts/06_run_full_cactus_slurm.sh
#
# FAIL-CLOSED: SLURM is NOT configured on this machine. This script refuses to
# run unless a real SLURM cluster is wired up AND the operator explicitly opts
# in with HOMOPAN_SLURM_READY=1. It must never (a) silently fall back to
# single_machine and pretend it used HPC, nor (b) destroy an in-progress
# jobstore. See SECURITY.md / agents.md for the safety rationale.
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

# ── Fail-closed gate ───────────────────────────────────────────────────────
# Refuse to run unless an operator has confirmed a real SLURM cluster exists.
# Without this, the old script ran on single_machine and marked the step done
# as if HPC had been used -- a silent lie about how the result was produced.
if [[ "${HOMOPAN_SLURM_READY:-0}" != "1" ]]; then
  die "SLURM is not configured. This script is fail-closed: it will not run on \
single_machine and pretend it used HPC, and it will not touch the jobstore. \
After provisioning a real SLURM cluster, re-run with HOMOPAN_SLURM_READY=1. \
For a local single-machine run, use scripts/06_run_full_cactus.sh instead."
fi

# Even when opted in, require an actual scheduler to be reachable.
command -v sbatch >/dev/null 2>&1 || die "HOMOPAN_SLURM_READY=1 but 'sbatch' not found on PATH. No SLURM scheduler reachable; refusing to run."
command -v squeue >/dev/null 2>&1 || die "HOMOPAN_SLURM_READY=1 but 'squeue' not found on PATH. No SLURM scheduler reachable; refusing to run."

acquire_step_lock "06_run_full_cactus"
require_done "03_make_seqfiles"
[[ -f "${SEQFILE_FULL}" ]] || die "Full seqfile not found: $(sanitize_path "${SEQFILE_FULL}")"
run_preflight "${SEQFILE_FULL}"

LOGFILE="${LOGS_DIR}/06_run_full_cactus_slurm.$(date +%Y%m%d_%H%M%S).log"

# ── Restart or fresh run (NEVER unconditionally delete the jobstore) ───────
# Mirrors 06_run_full_cactus.sh: only --restart when the jobstore was built
# from the SAME inputs; only wipe when the operator explicitly sets
# CACTUS_CLEAN=1. A blind `rm -rf` here used to destroy any run in progress.
RESTART_FLAG=()
if [[ -d "${JS_FULL}" ]]; then
  log_info "Existing jobstore found: $(sanitize_path "${JS_FULL}")"
  if [[ "${CACTUS_CLEAN:-}" == "1" ]]; then
    log_warn "CACTUS_CLEAN=1: removing old jobstore"
    rm -rf "${JS_FULL}"
    [[ -f "${HAL_FULL}" ]] && rm -f "${HAL_FULL}"
  else
    js_rc=0; check_jobstore_inputs "${JS_FULL}" "06_run_full_cactus" || js_rc=$?
    case "${js_rc}" in
      0) log_info "Jobstore inputs match current seqfile/tree; attempting --restart"
         RESTART_FLAG=(--restart) ;;
      2) log_warn "Jobstore has no inputs record (legacy); restarting but cannot verify it matches current inputs."
         RESTART_FLAG=(--restart) ;;
      *) die "Jobstore at $(sanitize_path "${JS_FULL}") was built from DIFFERENT inputs than the current seqfile/tree. Refusing --restart (would corrupt the alignment). Re-run with CACTUS_CLEAN=1 to start fresh." ;;
    esac
  fi
else
  [[ -f "${HAL_FULL}" ]] && rm -f "${HAL_FULL}"
fi

if (( ${#RESTART_FLAG[@]} == 0 )); then
  record_jobstore_inputs "${JS_FULL}" "06_run_full_cactus"
fi

# ── Run Cactus on the SLURM batch system ──────────────────────────────────
log_step "Running Cactus full alignment via SLURM"
log_info "SLURM Job ID: ${SLURM_JOB_ID:-<interactive>}"
log_info "Seqfile: $(sanitize_path "${SEQFILE_FULL}")"
log_info "Output:  $(sanitize_path "${HAL_FULL}")"
log_info "Mode:    ${RESTART_FLAG[*]:-fresh}"

START_TIME=$(date +%s)

# NOTE: run_cactus already adds `cactus --binariesMode local --retryCount N`.
# --batchSystem slurm dispatches Toil jobs to the real scheduler (NOT
# single_machine). retryCount (in run_cactus) absorbs transient job failures.
set +e
run_cactus \
  "${JS_FULL}" \
  "${SEQFILE_FULL}" \
  "${HAL_FULL}" \
  --batchSystem slurm \
  --realTimeLogging true \
  "${RESTART_FLAG[@]}" \
  2>&1 | tee "${LOGFILE}"
cactus_rc=${PIPESTATUS[0]}
set -e

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
HOURS=$(( ELAPSED / 3600 ))
MINS=$(( (ELAPSED % 3600) / 60 ))
log_info "Elapsed: ${HOURS}h ${MINS}m"

# ── Rollback partial HAL on failure (jobstore preserved for --restart) ─────
if (( cactus_rc != 0 )); then
  [[ -f "${HAL_FULL}" ]] && { log_warn "Removing partial/incomplete HAL"; rm -f "${HAL_FULL}"; }
  if (( cactus_rc == 124 )); then
    die "Cactus full alignment (SLURM) timed out after ${CACTUS_TIMEOUT:-172800}s. Jobstore preserved; re-run to --restart."
  fi
  die "Cactus full alignment (SLURM) failed (exit ${cactus_rc}). Jobstore preserved; re-run to resume (--restart)."
fi

# ── Verify output (structural gate, not just non-empty) ────────────────────
assert_hal_valid "${HAL_FULL}" "Full HAL"

log_ok "Cactus full alignment complete (SLURM, ${HOURS}h ${MINS}m)"
mark_done "06_run_full_cactus"
