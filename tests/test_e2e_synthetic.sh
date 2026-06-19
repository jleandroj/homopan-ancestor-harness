#!/usr/bin/env bash
# test_e2e_synthetic.sh -- End-to-end test of the non-Cactus pipeline plumbing
# (steps 01->02->03) on tiny synthetic genomes, in a throwaway project.
# Validates: FASTA validation+indexing, technical test-region extraction (incl.
# the non-homology caveat file), seqfile generation, and idempotency markers.
# Does NOT run Cactus (hours); it exercises orchestration, not biology.
# Requires host samtools. Run: bash tests/test_e2e_synthetic.sh
set -uo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
PASSED=0; FAILED=0
pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; ((PASSED++)) || true; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; ((FAILED++)) || true; }

if ! command -v samtools >/dev/null 2>&1; then
  echo -e "  ${YELLOW}[SKIP]${NC} host samtools not found"; exit 0
fi

SPECIES=(homo_sapiens pan_paniscus pan_troglodytes gorilla_gorilla_gorilla pongo_abelii)

# ── Build a throwaway project with copies of the scripts + tiny genomes ────
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/scripts" "${TMP}/genomes" "${TMP}/targets"
cp "${SRC_ROOT}/scripts/config.sh" "${TMP}/scripts/"
for s in 01_validate_fastas 02_make_test_fastas 03_make_seqfiles; do
  cp "${SRC_ROOT}/scripts/${s}.sh" "${TMP}/scripts/"
done
printf 'species\taccession\n' > "${TMP}/accessions.tsv"

# Tiny synthetic genome per species (3 kb, deterministic-ish ACGT)
for i in "${!SPECIES[@]}"; do
  sp="${SPECIES[$i]}"
  {
    echo ">chr_test_${sp}"
    yes "ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTAC" | head -n 60
  } > "${TMP}/genomes/${sp}.fa"
  samtools faidx "${TMP}/genomes/${sp}.fa" 2>/dev/null
done

# Satisfy require_done "00_check_env" (existence-only step)
printf 'timestamp=synthetic\ninputs_sha256=\n' > "${TMP}/targets/00_check_env.done"

echo ""
echo -e "${BOLD}E2E Synthetic Pipeline (01 -> 02 -> 03)${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"

run_step() { # <script> <label>
  if bash "${TMP}/scripts/$1" >"${TMP}/$1.log" 2>&1; then
    pass "ran $2"
  else
    fail "$2 exited non-zero"; sed 's/^/      /' "${TMP}/$1.log" | tail -12
  fi
}

echo ""; echo -e "${BOLD}1. Step execution${NC}"
run_step 01_validate_fastas.sh "01 validate_fastas"
run_step 02_make_test_fastas.sh "02 make_test_fastas"
run_step 03_make_seqfiles.sh    "03 make_seqfiles"

echo ""; echo -e "${BOLD}2. Expected outputs${NC}"
[[ -s "${TMP}/qc/genome_checksums.tsv" ]] && pass "01 wrote genome_checksums.tsv" || fail "missing genome_checksums.tsv"
n_test=$(ls "${TMP}"/test_genomes/*.fa 2>/dev/null | wc -l)
(( n_test >= 5 )) && pass "02 produced ${n_test} test FASTAs" || fail "02 produced ${n_test} test FASTAs (<5)"
[[ -f "${TMP}/test_genomes/README_TEST_REGIONS.txt" ]] && pass "02 wrote non-homology caveat" || fail "missing README_TEST_REGIONS.txt"
ls "${TMP}"/primates*.seqfile >/dev/null 2>&1 && pass "03 wrote a seqfile" || fail "03 produced no seqfile"

echo ""; echo -e "${BOLD}3. Idempotency markers${NC}"
for m in 01_validate_fastas 02_make_test_fastas 03_make_seqfiles; do
  if grep -qE '^inputs_sha256=' "${TMP}/targets/${m}.done" 2>/dev/null; then
    pass "marker ${m} has inputs hash"
  else
    fail "marker ${m} missing/!hash"
  fi
done

# Mutate a genome -> is_done must report stale (re-run needed)
echo ""; echo -e "${BOLD}4. Input change invalidates step${NC}"
(
  cd "${TMP}" || exit 1
  source "${TMP}/scripts/config.sh" >/dev/null 2>&1
  set +e
  echo ">chr_test_homo_sapiens" > "${TMP}/genomes/homo_sapiens.fa"
  echo "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT" >> "${TMP}/genomes/homo_sapiens.fa"
  samtools faidx "${TMP}/genomes/homo_sapiens.fa" 2>/dev/null
  is_done 01_validate_fastas >/dev/null 2>&1 && exit 10 || exit 0
)
[[ $? -eq 0 ]] && pass "01 detected changed genome (stale)" || fail "01 did not detect changed genome"

echo ""
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD}  Results: ${PASSED} passed, ${FAILED} failed${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo ""
(( FAILED == 0 )) || { echo -e "${RED}${BOLD}TESTS FAILED${NC}"; exit 1; }
echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"; exit 0
