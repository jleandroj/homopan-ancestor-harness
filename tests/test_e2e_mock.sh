#!/usr/bin/env bash
# test_e2e_mock.sh -- Full happy-path e2e (00 -> 10) with a MOCK Cactus/HAL
# toolchain (stub `apptainer` on PATH) on tiny synthetic genomes. Proves the
# orchestration produces a HAL, all ancestor FASTAs, and the report -- without
# the hours-long real alignment. Host samtools is used for real (tiny inputs).
# Run: bash tests/test_e2e_mock.sh
set -uo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
PASSED=0; FAILED=0
pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; ((PASSED++)) || true; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; ((FAILED++)) || true; }

command -v samtools >/dev/null 2>&1 || { echo -e "  ${YELLOW}[SKIP]${NC} host samtools missing"; exit 0; }

SPECIES=(homo_sapiens pan_paniscus pan_troglodytes gorilla_gorilla_gorilla pongo_abelii)
ANCS=(Anc_HomoPan Pan Homininae Root)

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/scripts" "${TMP}/genomes" "${TMP}/test_genomes" "${TMP}/bin"

# Copy the real scripts (config + all pipeline steps + orchestrator)
cp "${SRC_ROOT}/scripts/"*.sh "${TMP}/scripts/"
mkdir -p "${TMP}/scripts/lib"; cp "${SRC_ROOT}/scripts/lib/"*.sh "${TMP}/scripts/lib/" 2>/dev/null || true
printf 'species\taccession\n' > "${TMP}/accessions.tsv"
: > "${TMP}/cactus_v3.0.1.sif"   # dummy SIF (stub apptainer ignores contents)

# Tiny synthetic genomes
for sp in "${SPECIES[@]}"; do
  { echo ">chr_${sp}"; yes "ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTAC" | head -n 40; } > "${TMP}/genomes/${sp}.fa"
  samtools faidx "${TMP}/genomes/${sp}.fa" 2>/dev/null
done

# ── Stub apptainer: emulate cactus / halValidate / halStats / hal2fasta ───
cat > "${TMP}/bin/apptainer" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "apptainer version 1.0.0-mock"; exit 0; }
args=("$@"); [[ "${args[0]:-}" == "exec" ]] && args=("${args[@]:1}")
i=0
while (( i < ${#args[@]} )); do
  case "${args[$i]}" in
    --bind) i=$((i+2));;
    *.sif) i=$((i+1)); break;;
    --*) i=$((i+1));;
    *) break;;
  esac
done
tool="${args[$i]:-}"; rest=("${args[@]:$((i+1))}")
case "$tool" in
  which) echo "/usr/local/bin/${rest[0]:-x}"; exit 0;;
  cactus)
    for a in "${rest[@]}"; do [[ "$a" == "--version" ]] && { echo "9.1.2-mock"; exit 0; }; done
    for a in "${rest[@]}"; do [[ "$a" == "--help" ]] && { echo "options: --binariesMode --retryCount --seed --batchSystem"; exit 0; }; done
    pos=(); j=0
    while (( j < ${#rest[@]} )); do
      case "${rest[$j]}" in
        # value-taking options (must skip their argument so positionals stay aligned)
        --binariesMode|--batchSystem|--realTimeLogging|--retryCount|--seed) j=$((j+2));;
        --*) j=$((j+1));;
        *) pos+=("${rest[$j]}"); j=$((j+1));;
      esac
    done
    hal="${pos[2]:-}"; [[ -n "$hal" ]] || { echo "no hal" >&2; exit 1; }
    mkdir -p "$(dirname "$hal")"; printf 'MOCK-HAL\n' > "$hal"; exit 0;;
  halValidate) echo "File valid"; exit 0;;
  halStats)
    case "${rest[0]:-}" in
      --version) echo "v2.2-mock";;
      --genomes) echo "homo_sapiens, pan_paniscus, pan_troglodytes, gorilla_gorilla_gorilla, pongo_abelii, Anc_HomoPan, Pan, Homininae, Root";;
      --tree) echo "(((homo_sapiens,(pan_paniscus,pan_troglodytes)Pan)Anc_HomoPan,gorilla_gorilla_gorilla)Homininae,pongo_abelii)Root;";;
      --genomeLength) echo "2000";;
      *) echo "mock halStats";;
    esac
    exit 0;;
  hal2fasta)
    printf '>%s\nACGTACGTACGTACGTACGTACGTACGTACGT\n' "${rest[1]:-anc}"; exit 0;;
  *) exit 0;;
esac
STUB
chmod +x "${TMP}/bin/apptainer"

echo ""
echo -e "${BOLD}E2E (mock Cactus) -- run_all_full 00->10${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"

# Run the real orchestrator with the stub toolchain on PATH.
echo ""; echo -e "${BOLD}1. Orchestrator${NC}"
if PATH="${TMP}/bin:${PATH}" CACTUS_TIMEOUT=60 HOMOPAN_SKIP_PREFLIGHT=1 \
   HOMOPAN_IGNORE_TOOLCHAIN_LOCK=1 HOMOPAN_SANDBOX_COMPUTE=0 \
   bash "${TMP}/scripts/run_all_full.sh" >"${TMP}/run.log" 2>&1; then
  pass "run_all_full.sh completed 00->10"
else
  fail "run_all_full.sh failed"; sed 's/^/      /' "${TMP}/run.log" | tail -25
fi

echo ""; echo -e "${BOLD}2. Artifacts${NC}"
[[ -s "${TMP}/results/test/primates.test.hal" ]] && pass "test HAL produced" || fail "no test HAL"
[[ -s "${TMP}/results/full/primates.full.hal" ]] && pass "full HAL produced" || fail "no full HAL"
for a in "${ANCS[@]}"; do
  [[ -s "${TMP}/results/ancestors/${a}.fa" ]] && pass "ancestor ${a}.fa" || fail "missing ancestor ${a}.fa"
done
[[ -s "${TMP}/results/reports/HomoPan_ancestor_report.md" ]] && pass "report generated" || fail "no report"

echo ""; echo -e "${BOLD}3. Idempotency markers 00-10${NC}"
miss=0
for s in 00_check_env 01_validate_fastas 02_make_test_fastas 03_make_seqfiles 04_run_test_cactus 05_validate_test_hal 06_run_full_cactus 07_validate_full_hal 08_extract_ancestors 09_make_report; do
  [[ -f "${TMP}/targets/${s}.done" ]] || { miss=1; echo "      missing marker: ${s}"; }
done
(( miss == 0 )) && pass "all step markers present" || fail "some step markers missing"

echo ""
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD}  Results: ${PASSED} passed, ${FAILED} failed${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo ""
(( FAILED == 0 )) || { echo -e "${RED}${BOLD}TESTS FAILED${NC}"; exit 1; }
echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"; exit 0
