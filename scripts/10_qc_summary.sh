#!/usr/bin/env bash
# 10_qc_summary.sh -- Colored QC summary in terminal
set -euo pipefail
source "$(dirname "$0")/config.sh"

script_banner "10 - QC Summary"

echo -e "${BOLD}Pipeline Status${NC}"
echo -e "${BOLD}────────────────────────────────────────${NC}"

# ── Step completion status ────────────────────────────────────────────────
STEPS=(
  "00_check_env:Environment check"
  "01_validate_fastas:FASTA validation"
  "02_make_test_fastas:Test FASTA creation"
  "03_make_seqfiles:Seqfile generation"
  "04_run_test_cactus:Test Cactus alignment"
  "05_validate_test_hal:Test HAL validation"
  "06_run_full_cactus:Full Cactus alignment"
  "07_validate_full_hal:Full HAL validation"
  "08_extract_ancestors:Ancestor extraction"
  "09_make_report:Report generation"
)

DONE_COUNT=0
TOTAL=${#STEPS[@]}

for entry in "${STEPS[@]}"; do
  step="${entry%%:*}"
  label="${entry#*:}"
  if is_done "${step}"; then
    echo -e "  ${GREEN}[DONE]${NC} ${label}"
    ((DONE_COUNT++)) || true
  else
    echo -e "  ${RED}[----]${NC} ${label}"
  fi
done

echo ""
echo -e "${BOLD}Progress: ${DONE_COUNT}/${TOTAL} steps complete${NC}"
echo ""

# ── Key files ─────────────────────────────────────────────────────────────
echo -e "${BOLD}Key Files${NC}"
echo -e "${BOLD}────────────────────────────────────────${NC}"

check_file() {
  local f="$1" label="$2"
  if [[ -f "$f" ]] && [[ -s "$f" ]]; then
    local sz
    sz=$(du -h "$f" | cut -f1)
    echo -e "  ${GREEN}[OK]${NC} ${label} (${sz})"
  else
    echo -e "  ${RED}[--]${NC} ${label}"
  fi
}

check_file "${SEQFILE_FULL}" "Full seqfile"
check_file "${SEQFILE_TEST}" "Test seqfile"
check_file "${HAL_TEST}" "Test HAL"
check_file "${HAL_FULL}" "Full HAL"

for anc in "${ANCESTOR_NODES[@]}"; do
  check_file "${RESULTS_ANCESTORS}/${anc}.fa" "Ancestor: ${anc}"
done

check_file "${RESULTS_REPORTS}/HomoPan_ancestor_report.md" "Final report"

echo ""

# ── Disk usage ────────────────────────────────────────────────────────────
echo -e "${BOLD}Disk Usage${NC}"
echo -e "${BOLD}────────────────────────────────────────${NC}"
echo -e "  Project total: $(du -sh "${PROJECT_ROOT}" 2>/dev/null | cut -f1)"
echo -e "  Genomes:       $(du -sh "${GENOMES_DIR}" 2>/dev/null | cut -f1)"
echo -e "  Work/jobstore: $(du -sh "${PROJECT_ROOT}/work" 2>/dev/null | cut -f1)"
echo -e "  Results:       $(du -sh "${RESULTS_DIR}" 2>/dev/null | cut -f1)"
echo -e "  Available:     $(df -h "${PROJECT_ROOT}" | awk 'NR==2{print $4}')"
echo ""

# ── QC files ──────────────────────────────────────────────────────────────
echo -e "${BOLD}QC Files${NC}"
echo -e "${BOLD}────────────────────────────────────────${NC}"
if [[ -d "${QC_DIR}" ]]; then
  for f in "${QC_DIR}"/*; do
    [[ -f "$f" ]] && echo -e "  $(du -h "$f" | cut -f1)\t$(basename "$f")"
  done
fi
echo ""

mark_done "10_qc_summary"
