#!/usr/bin/env bash
# 00_check_env.sh -- Verify tools, genomes, disk, and container
set -euo pipefail
source "$(dirname "$0")/config.sh"

script_banner "00 - Environment Check"

ERRORS=0
WARNS=0

check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then
    log_ok "$label"
  else
    log_error "$label"
    ((ERRORS++)) || true
  fi
}

warn_check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then
    log_ok "$label"
  else
    log_warn "$label"
    ((WARNS++)) || true
  fi
}

# ── Host tools ────────────────────────────────────────────────────────────
log_step "Checking host tools"
check "samtools on host"   command -v samtools
check "apptainer on host"  command -v apptainer
warn_check "bedtools on host"   command -v bedtools
warn_check "jq on host"        command -v jq

log_info "samtools version: $(samtools --version 2>/dev/null | head -1 || echo 'N/A')"
log_info "apptainer version: $(apptainer --version 2>/dev/null || echo 'N/A')"

# ── Container ─────────────────────────────────────────────────────────────
log_step "Checking container"
check "SIF exists: $(sanitize_path "${SIF}")" test -f "${SIF}"

if [[ -f "${SIF}" ]]; then
  check "cactus in container"      run_in_container which cactus
  check "halStats in container"    run_in_container which halStats
  check "halValidate in container" run_in_container which halValidate
  check "hal2fasta in container"   run_in_container which hal2fasta

  log_info "halStats version: $(run_halStats --version 2>&1 | head -1 || echo 'N/A')"
fi

# ── Genomes ───────────────────────────────────────────────────────────────
log_step "Checking genomes (${#SPECIES[@]} species)"
for sp in "${SPECIES[@]}"; do
  FA="${GENOMES_DIR}/${sp}.fa"
  FAI="${GENOMES_DIR}/${sp}.fa.fai"
  check "Genome: ${sp}.fa"     test -s "${FA}"
  check "Index:  ${sp}.fa.fai" test -s "${FAI}"
done

# ── Seqfiles ──────────────────────────────────────────────────────────────
log_step "Checking seqfiles"
warn_check "Full seqfile exists" test -f "${SEQFILE_FULL}"
warn_check "Test seqfile exists" test -f "${SEQFILE_TEST}"

# ── Disk space ────────────────────────────────────────────────────────────
log_step "Checking disk space"
AVAIL_GB=$(df -BG "${PROJECT_ROOT}" | awk 'NR==2{print $4}' | tr -d 'G')
log_info "Available: ${AVAIL_GB} GB"
if (( AVAIL_GB < DISK_WARN_GB )); then
  log_warn "Low disk: ${AVAIL_GB} GB (recommended: ${DISK_WARN_GB}+ GB)"
  ((WARNS++)) || true
else
  log_ok "Disk space: ${AVAIL_GB} GB"
fi

# ── Directories ───────────────────────────────────────────────────────────
log_step "Checking directories"
for d in scripts logs qc targets results genomes test_genomes work; do
  check "Dir: ${d}/" test -d "${PROJECT_ROOT}/${d}"
done

# ── Capture environment ──────────────────────────────────────────────────
capture_env "${QC_DIR}/environment.txt"

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}────────────────────────────────────────${NC}"
if (( ERRORS > 0 )); then
  log_error "Environment check: ${ERRORS} error(s), ${WARNS} warning(s)"
  exit 1
else
  if (( WARNS > 0 )); then
    log_warn "Environment check passed with ${WARNS} warning(s)"
  else
    log_ok "Environment check passed"
  fi
fi

mark_done "00_check_env"
