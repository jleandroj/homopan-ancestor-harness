#!/usr/bin/env bash
# test_compare_runs.sh -- scripts/compare_runs.sh: identical repro{} => verdict
# REPRODUCIBLE (exit 0); a differing output hash => diff shown + exit 1. Meta
# differences (run_id/timestamp) must NOT affect the verdict.
export HOMOPAN_RUN_NS="__test_cmp_$$"
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SRC_ROOT}/scripts/config.sh" >/dev/null 2>&1
set +e
RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0
ok()  { echo -e "  ${GREEN}[PASS]${NC} $*"; ((PASS++)) || true; }
bad() { echo -e "  ${RED}[FAIL]${NC} $*"; ((FAIL++)) || true; }

mkdir -p "${QC_DIR}/manifests"
emit() {  # <run_id> <hal_sha> <repro_sha>
  cat > "${QC_DIR}/manifests/$1.json" <<EOF
{"schema":2,
 "repro":{"cactus":"9.1.2","cactus_seed":"0","sif_sha256":"deadbeef","newick":"(x);",
          "outputs":{"full_hal_sha256":"$2"}},
 "repro_sha256":"$3",
 "meta":{"run_id":"$1","timestamp":"2026-01-01T00:00:0$1","host":"h"}}
EOF
}
# A and B: identical repro (+repro_sha), different meta. C: different output.
emit A AAAAAAAA reprohashAB
emit B AAAAAAAA reprohashAB
emit C CCCCCCCC reprohashC

echo ""; echo -e "${BOLD}compare_runs verdicts${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"

OUT_AB="$(bash "${SRC_ROOT}/scripts/compare_runs.sh" A B 2>&1)"; RC_AB=$?
echo "${OUT_AB}" | grep -q 'REPRODUCIBLE' && (( RC_AB == 0 )) \
  && ok "identical repro => REPRODUCIBLE (exit 0), meta diff ignored" \
  || { bad "A vs B should be REPRODUCIBLE (rc=${RC_AB})"; echo "${OUT_AB}" | sed 's/^/      /'; }

OUT_AC="$(bash "${SRC_ROOT}/scripts/compare_runs.sh" A C 2>&1)"; RC_AC=$?
{ (( RC_AC == 1 )) && echo "${OUT_AC}" | grep -q 'full_hal_sha256'; } \
  && ok "differing output => diff shown + exit 1" \
  || { bad "A vs C should differ on full_hal_sha256 (rc=${RC_AC})"; echo "${OUT_AC}" | sed 's/^/      /'; }

# --list works
bash "${SRC_ROOT}/scripts/compare_runs.sh" --list 2>&1 | grep -q '^A$' \
  && ok "--list enumerates run ids" || bad "--list did not list run A"

rm -rf "${SRC_ROOT}/runs/${HOMOPAN_RUN_NS}" 2>/dev/null
echo ""
echo -e "${BOLD}  Results: ${PASS} passed, ${FAIL} failed${NC}"
(( FAIL == 0 )) || { echo -e "${RED}${BOLD}TESTS FAILED${NC}"; exit 1; }
echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"; exit 0
