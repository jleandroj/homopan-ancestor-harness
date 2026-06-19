#!/usr/bin/env bash
# init.sh -- Pre-flight gate with content-based hash of contract surface
# Must pass before any agent can modify files in this repository.
set -euo pipefail

# ── Project root ──────────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${PROJECT_ROOT}/.claude"
GATE_PASS="${CLAUDE_DIR}/.gate_pass"

# ── Colors ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

ERRORS=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; ((ERRORS++)) || true; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "  ${BOLD}[INFO]${NC} $*"; }

echo ""
echo -e "${BOLD}HomoPan Ancestor -- Pre-flight Check${NC}"
echo -e "${BOLD}$(date)${NC}"
echo -e "${BOLD}────────────────────────────────────────${NC}"

# ── 1. Contract files ────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}1. Contract Surface${NC}"

AGENTS_MD="${PROJECT_ROOT}/agents.md"
CLAUDE_MD="${PROJECT_ROOT}/CLAUDE.md"

if [[ -f "${AGENTS_MD}" ]]; then
  pass "agents.md exists"
else
  fail "agents.md MISSING"
fi

if [[ -f "${CLAUDE_MD}" ]]; then
  pass "CLAUDE.md exists"
else
  fail "CLAUDE.md MISSING"
fi

# ── 2. Mandatory markers in agents.md ────────────────────────────────────
echo ""
echo -e "${BOLD}2. Contract Markers${NC}"

if [[ -f "${AGENTS_MD}" ]]; then
  for marker in "Protocolo de Seguridad para Agentes" "Regla de Detencion Absoluta" "init.sh"; do
    if grep -q "${marker}" "${AGENTS_MD}" 2>/dev/null; then
      pass "Marker: '${marker}'"
    else
      fail "Missing marker in agents.md: '${marker}'"
    fi
  done
fi

# ── 3. Essential directories ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}3. Directories${NC}"

for d in genomes scripts; do
  if [[ -d "${PROJECT_ROOT}/${d}" ]]; then
    pass "Dir: ${d}/"
  else
    fail "Dir missing: ${d}/"
  fi
done

for d in logs qc targets results .claude/agents; do
  if [[ -d "${PROJECT_ROOT}/${d}" ]]; then
    pass "Dir: ${d}/"
  else
    warn "Dir missing: ${d}/ (creating)"
    mkdir -p "${PROJECT_ROOT}/${d}"
  fi
done

# ── 4. Container ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}4. Container${NC}"

SIF="${PROJECT_ROOT}/cactus_v3.0.1.sif"
SIF_EXPECTED_SHA="0124bac3b489d89862205660443df11d98bccc7c17268406433bccf6ad27ed57"
if [[ -f "${SIF}" ]]; then
  pass "Container: cactus_v3.0.1.sif ($(du -h "${SIF}" | cut -f1))"
  info "Verifying SIF checksum (this takes a moment)..."
  SIF_SHA=$(sha256sum "${SIF}" | cut -d' ' -f1)
  if [[ "${SIF_SHA}" == "${SIF_EXPECTED_SHA}" ]]; then
    pass "SIF checksum: ${SIF_SHA:0:16}..."
  else
    fail "SIF checksum mismatch! Expected ${SIF_EXPECTED_SHA:0:16}..., got ${SIF_SHA:0:16}..."
  fi
else
  fail "Container MISSING: cactus_v3.0.1.sif"
fi

# ── 5. Genomes ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}5. Genomes${NC}"

SPECIES=(homo_sapiens pan_paniscus pan_troglodytes gorilla_gorilla_gorilla pongo_abelii)
for sp in "${SPECIES[@]}"; do
  FA="${PROJECT_ROOT}/genomes/${sp}.fa"
  if [[ -f "${FA}" ]] && [[ -s "${FA}" ]]; then
    pass "${sp}.fa ($(du -h "${FA}" | cut -f1))"
  else
    fail "${sp}.fa missing or empty"
  fi
done

# ── 6. Scripts ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}6. Scripts${NC}"

EXPECTED_SCRIPTS=(
  config.sh
  00_check_env.sh
  01_validate_fastas.sh
  02_make_test_fastas.sh
  03_make_seqfiles.sh
  04_run_test_cactus.sh
  05_validate_test_hal.sh
  06_run_full_cactus.sh
  06_run_full_cactus_slurm.sh
  07_validate_full_hal.sh
  08_extract_ancestors.sh
  09_make_report.sh
  10_qc_summary.sh
  run_all_test.sh
  run_all_full.sh
)

for s in "${EXPECTED_SCRIPTS[@]}"; do
  if [[ -f "${PROJECT_ROOT}/scripts/${s}" ]]; then
    if [[ -x "${PROJECT_ROOT}/scripts/${s}" ]]; then
      pass "scripts/${s}"
    else
      warn "scripts/${s} exists but not executable"
    fi
  else
    fail "scripts/${s} MISSING"
  fi
done

# ── 7. Tools ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}7. Host Tools${NC}"

for tool in samtools apptainer; do
  if command -v "${tool}" &>/dev/null; then
    VER=$("${tool}" --version 2>/dev/null | head -1 || echo "?")
    pass "${tool}: ${VER}"
  else
    fail "${tool} not found"
  fi
done

# jq: check PATH then conda env
if command -v jq &>/dev/null; then
  pass "jq: $(jq --version 2>/dev/null)"
elif [[ -x "${HOME}/miniconda3/envs/homopan_ancestor/bin/jq" ]]; then
  pass "jq: $(${HOME}/miniconda3/envs/homopan_ancestor/bin/jq --version 2>/dev/null) (in conda env)"
else
  warn "jq not found (hooks may fail)"
fi

# ── 8. Disk ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}8. Disk Space${NC}"

AVAIL_GB=$(df -BG "${PROJECT_ROOT}" | awk 'NR==2{print $4}' | tr -d 'G')
info "Primary: ${AVAIL_GB} GB free"

if [[ -d "/mnt/s1" ]]; then
  AVAIL_S1=$(df -BG /mnt/s1 | awk 'NR==2{print $4}' | tr -d 'G')
  info "Overflow (/mnt/s1): ${AVAIL_S1} GB free"
fi

# ── 9. Generate gate pass ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}9. Gate Pass${NC}"

if (( ERRORS > 0 )); then
  echo ""
  echo -e "${RED}${BOLD}════════════════════════════════════════${NC}"
  echo -e "${RED}${BOLD}  STOP: ${ERRORS} error(s) detected${NC}"
  echo -e "${RED}${BOLD}  Agent must NOT proceed.${NC}"
  echo -e "${RED}${BOLD}════════════════════════════════════════${NC}"
  echo ""
  exit 1
fi

# Content-based hash of FULL security surface (contract + infrastructure)
# Any change to these files invalidates the gate pass.
SECURITY_FILES=(
  "${CLAUDE_MD}"
  "${AGENTS_MD}"
  "${CLAUDE_DIR}/gate_check.sh"
  "${CLAUDE_DIR}/bitacora_log.sh"
  "${CLAUDE_DIR}/settings.json"
  "${PROJECT_ROOT}/init.sh"
)

mkdir -p "${CLAUDE_DIR}"

info "Security surface (${#SECURITY_FILES[@]} files):"
MISSING_SEC=0
for sf in "${SECURITY_FILES[@]}"; do
  if [[ -f "${sf}" ]]; then
    pass "  $(basename "${sf}")"
  else
    fail "  $(basename "${sf}") MISSING"
    ((MISSING_SEC++)) || true
  fi
done

if (( MISSING_SEC > 0 )); then
  fail "Cannot generate gate pass: ${MISSING_SEC} security file(s) missing"
  exit 1
fi

HASH=$(sha256sum "${SECURITY_FILES[@]}" 2>/dev/null | sha256sum | cut -d' ' -f1)
echo "${HASH}  $(date -Iseconds)" > "${GATE_PASS}"
pass "Gate pass generated: ${HASH:0:16}..."

echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ALL CHECKS PASSED${NC}"
echo -e "${GREEN}${BOLD}  Agent may proceed.${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo ""
