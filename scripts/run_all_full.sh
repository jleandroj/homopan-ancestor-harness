#!/usr/bin/env bash
# run_all_full.sh -- Orchestrator: run complete full pipeline with idempotency
# Skips steps already marked done. To re-run: rm targets/*.done
set -euo pipefail
source "$(dirname "$0")/config.sh"

script_banner "HomoPan Full Pipeline (Orchestrator)"

# ── Pipeline lock (prevents concurrent orchestrator runs) ────────────────
exec {_PIPELINE_LOCK_FD}>"${TARGETS_DIR}/pipeline_full.lock"
if ! flock -n "${_PIPELINE_LOCK_FD}"; then
  die "Another full pipeline is already running"
fi

STEPS=(
  "00_check_env"
  "01_validate_fastas"
  "02_make_test_fastas"
  "03_make_seqfiles"
  "04_run_test_cactus"
  "05_validate_test_hal"
  "06_run_full_cactus"
  "07_validate_full_hal"
  "08_extract_ancestors"
  "09_make_report"
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

  log_step "Running ${step}"
  if bash "${SCRIPT}"; then
    ((RAN++)) || true
  else
    log_error "Step ${step} FAILED (exit $?)"
    ((FAILED++)) || true
    break
  fi
done

echo ""
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD}  Full Pipeline Summary${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo -e "  Ran:     ${RAN}"
echo -e "  Skipped: ${SKIPPED}"
echo -e "  Failed:  ${FAILED}"
echo -e "  Total:   ${TOTAL}"
echo ""

if (( FAILED > 0 )); then
  die "Full pipeline failed at step above"
fi

log_ok "Full pipeline complete"
