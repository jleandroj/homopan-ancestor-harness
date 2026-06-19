#!/usr/bin/env bash
# 06_run_full_cactus.sh -- Run Cactus alignment on full genomes
set -euo pipefail
source "$(dirname "$0")/config.sh"

script_banner "06 - Run Full Cactus"

acquire_step_lock "06_run_full_cactus"
require_done "03_make_seqfiles"
[[ -f "${SEQFILE_FULL}" ]] || die "Full seqfile not found: $(sanitize_path "${SEQFILE_FULL}")"

# ── Disk check (full run needs more space) ────────────────────────────────
check_disk "${DISK_FULL_MIN_GB}" || log_warn "Proceeding despite low disk (user responsibility)"

LOGFILE="${LOGS_DIR}/06_run_full_cactus.$(date +%Y%m%d_%H%M%S).log"

# ── Restart or fresh run ──────────────────────────────────────────────────
RESTART_FLAG=()
if [[ -d "${JS_FULL}" ]]; then
  log_info "Existing jobstore found: $(sanitize_path "${JS_FULL}")"
  if [[ "${CACTUS_CLEAN:-}" == "1" ]]; then
    log_warn "CACTUS_CLEAN=1: removing old jobstore"
    rm -rf "${JS_FULL}"
    [[ -f "${HAL_FULL}" ]] && rm -f "${HAL_FULL}"
  else
    log_info "Attempting --restart from existing jobstore"
    log_info "(To force fresh run: CACTUS_CLEAN=1 bash scripts/06_run_full_cactus.sh)"
    RESTART_FLAG=(--restart)
  fi
else
  # Fresh run: remove stale HAL if any
  [[ -f "${HAL_FULL}" ]] && rm -f "${HAL_FULL}"
fi

# ── Run Cactus ────────────────────────────────────────────────────────────
log_step "Running Cactus full alignment (this will take hours)"
log_info "Seqfile: $(sanitize_path "${SEQFILE_FULL}")"
log_info "Output:  $(sanitize_path "${HAL_FULL}")"
log_info "Log:     $(sanitize_path "${LOGFILE}")"
log_info "Cores:   $(nproc)"
log_info "RAM:     $(free -g | awk '/Mem:/{print $7}') GB available"
log_info "Mode:    ${RESTART_FLAG[*]:-fresh}"

START_TIME=$(date +%s)

timeout "${CACTUS_TIMEOUT:-172800}" \
  run_cactus \
  "${JS_FULL}" \
  "${SEQFILE_FULL}" \
  "${HAL_FULL}" \
  --batchSystem single_machine \
  --realTimeLogging true \
  "${RESTART_FLAG[@]}" \
  2>&1 | tee "${LOGFILE}"

if (( PIPESTATUS[0] == 124 )); then
  die "Cactus full alignment timed out after ${CACTUS_TIMEOUT:-172800}s"
fi

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
HOURS=$(( ELAPSED / 3600 ))
MINS=$(( (ELAPSED % 3600) / 60 ))

log_info "Elapsed: ${HOURS}h ${MINS}m"

# ── Verify output ─────────────────────────────────────────────────────────
assert_file_nonempty "${HAL_FULL}" "Full HAL"

log_ok "Cactus full alignment complete (${HOURS}h ${MINS}m)"
mark_done "06_run_full_cactus"
