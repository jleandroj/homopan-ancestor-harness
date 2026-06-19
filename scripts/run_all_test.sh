#!/usr/bin/env bash
# run_all_test.sh -- Orchestrator: run complete test pipeline with idempotency
# Skips steps already marked done. To re-run: rm targets/*.done
set -euo pipefail
source "$(dirname "$0")/config.sh"

script_banner "HomoPan Test Pipeline (Orchestrator)"

# ── Pipeline lock (prevents concurrent orchestrator runs) ────────────────
# ONE lock shared by BOTH orchestrators (test + full). They write the same
# targets/, work/ and seqfiles, so they must never run concurrently -- a
# per-mode lock would let them race and corrupt shared state.
exec {_PIPELINE_LOCK_FD}>"${TARGETS_DIR}/pipeline.lock"
if ! flock -n "${_PIPELINE_LOCK_FD}"; then
  die "Another pipeline (test or full) is already running"
fi

STEPS=(
  "00_check_env"
  "01_validate_fastas"
  "02_make_test_fastas"
  "03_make_seqfiles"
  "04_run_test_cactus"
  "05_validate_test_hal"
  "10_qc_summary"
)

TOTAL=${#STEPS[@]}
SKIPPED=0
RAN=0
FAILED=0

for step in "${STEPS[@]}"; do
  if is_done "${step}"; then
    log_info "Skipping ${step} (already done)"
    ((SKIPPED++)) || true
    continue
  fi

  SCRIPT="${SCRIPTS_DIR}/${step}.sh"
  if [[ ! -x "${SCRIPT}" ]]; then
    die "Script not found or not executable: $(sanitize_path "${SCRIPT}")"
  fi

  if run_step_with_retry "${step}" "${SCRIPT}"; then
    ((RAN++)) || true
  else
    ((FAILED++)) || true
    break
  fi
done

echo ""
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD}  Test Pipeline Summary${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo -e "  Ran:     ${RAN}"
echo -e "  Skipped: ${SKIPPED}"
echo -e "  Failed:  ${FAILED}"
echo -e "  Total:   ${TOTAL}"
echo ""

if (( FAILED > 0 )); then
  die "Test pipeline failed at step above"
fi

log_ok "Test pipeline complete"
