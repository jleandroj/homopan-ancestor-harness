#!/usr/bin/env bash
# test_manifest.sh -- per-run manifest is IMMUTABLE (a later run never clobbers
# an earlier one), carries the mandatory repro fields, and its repro_sha256 is
# a pure function of the repro{} block (independent of run_id/timestamp/host).
export HOMOPAN_RUN_NS="__test_man_$$"
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SRC_ROOT}/scripts/config.sh" >/dev/null 2>&1
set +e
RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0
ok()  { echo -e "  ${GREEN}[PASS]${NC} $*"; ((PASS++)) || true; }
bad() { echo -e "  ${RED}[FAIL]${NC} $*"; ((FAIL++)) || true; }

TMP="$(mktemp -d)"
run_in_container() { echo "cactus 9.1.2-stub"; }   # avoid real apptainer
SIF="${TMP}/fake.sif"; : > "${SIF}"
printf 'homo_sapiens\tdeadbeef\t123\n' > "${QC_DIR}/genome_checksums.tsv"
printf 'Anc_HomoPan\tcafef00d\t1000\t0.0100\n' > "${QC_DIR}/ancestor_checksums.tsv"

echo ""; echo -e "${BOLD}Manifest immutability + repro_sha256 stability${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"

RUN_ID="manrun1"; write_run_manifest >/dev/null 2>&1
M1="${QC_DIR}/manifests/manrun1.json"
[[ -f "${M1}" ]] && ok "run1 manifest written" || bad "run1 manifest missing"
jq -e '.schema==2 and .repro.sif_sha256 and .repro.inputs.genomes and .meta.run_id=="manrun1"' < "${M1}" >/dev/null 2>&1 \
  && ok "mandatory fields present (schema/repro/inputs/meta)" || bad "mandatory fields missing"
RS1=$(jq -r '.repro_sha256' < "${M1}"); C1=$(cat "${M1}")

# Second run: different run_id, SAME repro inputs.
RUN_ID="manrun2"; write_run_manifest >/dev/null 2>&1
M2="${QC_DIR}/manifests/manrun2.json"
[[ -f "${M2}" ]] && ok "run2 manifest written (separate file)" || bad "run2 manifest missing"
[[ "$(cat "${M1}")" == "${C1}" ]] && ok "run1 manifest IMMUTABLE (untouched by run2)" || bad "run1 manifest was overwritten"
RS2=$(jq -r '.repro_sha256' < "${M2}")
[[ "${RS1}" == "${RS2}" && -n "${RS1}" ]] && ok "repro_sha256 stable across runs (ignores run_id/time): ${RS1:0:12}..." || bad "repro_sha256 changed (RS1=${RS1:0:12} RS2=${RS2:0:12})"
r1=$(jq -r '.meta.run_id' < "${M1}"); r2=$(jq -r '.meta.run_id' < "${M2}")
[[ "${r1}" != "${r2}" ]] && ok "meta.run_id differs (${r1} vs ${r2})" || bad "meta.run_id should differ"

# Changing an input must change repro_sha256.
printf 'homo_sapiens\tNEWHASH\t999\n' > "${QC_DIR}/genome_checksums.tsv"
RUN_ID="manrun3"; write_run_manifest >/dev/null 2>&1
RS3=$(jq -r '.repro_sha256' < "${QC_DIR}/manifests/manrun3.json")
[[ "${RS3}" != "${RS1}" ]] && ok "input change => repro_sha256 changes (${RS3:0:12}...)" || bad "input change did NOT change repro_sha256"

rm -rf "${TMP}" "${SRC_ROOT}/runs/${HOMOPAN_RUN_NS}" 2>/dev/null
echo ""
echo -e "${BOLD}  Results: ${PASS} passed, ${FAIL} failed${NC}"
(( FAIL == 0 )) || { echo -e "${RED}${BOLD}TESTS FAILED${NC}"; exit 1; }
echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"; exit 0
