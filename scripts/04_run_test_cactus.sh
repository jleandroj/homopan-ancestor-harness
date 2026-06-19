#!/usr/bin/env bash
# 04_run_test_cactus.sh -- Run Cactus alignment on test (1 Mb) genomes
set -euo pipefail
source "$(dirname "$0")/config.sh"

script_banner "04 - Run Test Cactus"

acquire_step_lock "04_run_test_cactus"
require_done "03_make_seqfiles"
[[ -f "${SEQFILE_TEST}" ]] || die "Test seqfile not found: $(sanitize_path "${SEQFILE_TEST}")"

LOGFILE="${LOGS_DIR}/04_run_test_cactus.$(date +%Y%m%d_%H%M%S).log"

# ── Restart or fresh run ──────────────────────────────────────────────────
RESTART_FLAG=()
if [[ -d "${JS_TEST}" ]]; then
  log_info "Existing jobstore found: $(sanitize_path "${JS_TEST}")"
  if [[ "${CACTUS_CLEAN:-}" == "1" ]]; then
    log_warn "CACTUS_CLEAN=1: removing old jobstore"
    rm -rf "${JS_TEST}"
    [[ -f "${HAL_TEST}" ]] && rm -f "${HAL_TEST}"
  else
    log_info "Attempting --restart from existing jobstore"
    RESTART_FLAG=(--restart)
  fi
else
  # Fresh run: remove stale HAL if any
  [[ -f "${HAL_TEST}" ]] && rm -f "${HAL_TEST}"
fi

# ── Run Cactus ────────────────────────────────────────────────────────────
log_step "Running Cactus test alignment"
log_info "Seqfile: $(sanitize_path "${SEQFILE_TEST}")"
log_info "Output:  $(sanitize_path "${HAL_TEST}")"
log_info "Log:     $(sanitize_path "${LOGFILE}")"
log_info "Mode:    ${RESTART_FLAG[*]:-fresh}"

timeout "${CACTUS_TIMEOUT:-172800}" \
  run_cactus \
  "${JS_TEST}" \
  "${SEQFILE_TEST}" \
  "${HAL_TEST}" \
  --batchSystem single_machine \
  --realTimeLogging true \
  "${RESTART_FLAG[@]}" \
  2>&1 | tee "${LOGFILE}"

if (( PIPESTATUS[0] == 124 )); then
  die "Cactus test alignment timed out after ${CACTUS_TIMEOUT:-172800}s"
fi

# ── Verify output ─────────────────────────────────────────────────────────
assert_file_nonempty "${HAL_TEST}" "Test HAL"

log_ok "Cactus test alignment complete"
mark_done "04_run_test_cactus"
