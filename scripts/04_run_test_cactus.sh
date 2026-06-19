#!/usr/bin/env bash
# 04_run_test_cactus.sh -- Run Cactus alignment on test (1 Mb) genomes
set -euo pipefail
source "$(dirname "$0")/config.sh"

script_banner "04 - Run Test Cactus"

acquire_step_lock "04_run_test_cactus"
require_done "03_make_seqfiles"
[[ -f "${SEQFILE_TEST}" ]] || die "Test seqfile not found: $(sanitize_path "${SEQFILE_TEST}")"
run_preflight "${SEQFILE_TEST}"

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
    # Guard: only --restart if the jobstore was built from the SAME inputs.
    js_rc=0; check_jobstore_inputs "${JS_TEST}" "04_run_test_cactus" || js_rc=$?
    case "${js_rc}" in
      0) log_info "Jobstore inputs match current seqfile/tree; attempting --restart"
         RESTART_FLAG=(--restart) ;;
      2) log_warn "Jobstore has no inputs record (legacy); restarting but cannot verify it matches current inputs."
         log_warn "If the result looks wrong, re-run with CACTUS_CLEAN=1."
         RESTART_FLAG=(--restart) ;;
      *) die "Jobstore at $(sanitize_path "${JS_TEST}") was built from DIFFERENT inputs than the current test seqfile/tree. Refusing --restart. Re-run with CACTUS_CLEAN=1 to start fresh." ;;
    esac
  fi
else
  # Fresh run: remove stale HAL if any
  [[ -f "${HAL_TEST}" ]] && rm -f "${HAL_TEST}"
fi

# Record the inputs this jobstore is being built from (for future --restart).
if (( ${#RESTART_FLAG[@]} == 0 )); then
  record_jobstore_inputs "${JS_TEST}" "04_run_test_cactus"
fi

# ── Run Cactus ────────────────────────────────────────────────────────────
log_step "Running Cactus test alignment"
log_info "Seqfile: $(sanitize_path "${SEQFILE_TEST}")"
log_info "Output:  $(sanitize_path "${HAL_TEST}")"
log_info "Log:     $(sanitize_path "${LOGFILE}")"
log_info "Mode:    ${RESTART_FLAG[*]:-fresh}"

# Capture cactus's own exit code (not tee's) without letting set -e abort
# first, so we can roll back a partial HAL before reporting the failure.
set +e
run_cactus \
  "${JS_TEST}" \
  "${SEQFILE_TEST}" \
  "${HAL_TEST}" \
  --batchSystem single_machine \
  --realTimeLogging true \
  "${RESTART_FLAG[@]}" \
  2>&1 | tee "${LOGFILE}"
cactus_rc=${PIPESTATUS[0]}
set -e

# ── Rollback partial HAL on failure (jobstore is preserved for --restart) ──
if (( cactus_rc != 0 )); then
  [[ -f "${HAL_TEST}" ]] && { log_warn "Removing partial/incomplete HAL"; rm -f "${HAL_TEST}"; }
  if (( cactus_rc == 124 )); then
    die "Cactus test alignment timed out after ${CACTUS_TIMEOUT:-172800}s. Jobstore preserved; re-run to --restart."
  fi
  die "Cactus test alignment failed (exit ${cactus_rc}). Jobstore preserved; re-run to resume (--restart)."
fi

# ── Verify output (structural gate, not just non-empty) ────────────────────
assert_hal_valid "${HAL_TEST}" "Test HAL"

log_ok "Cactus test alignment complete"
mark_done "04_run_test_cactus"
