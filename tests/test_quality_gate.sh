#!/usr/bin/env bash
# test_quality_gate.sh -- ancestral-FASTA N-fraction gate (#4) + per-run
# manifest (#1/#5). Runs in an isolated namespace so it never touches real
# pipeline state. No Cactus/container needed (the manifest's container call is
# stubbed).
export HOMOPAN_RUN_NS="__test_qa_$$"
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SRC_ROOT}/scripts/config.sh" >/dev/null 2>&1
set +e   # manage exit codes explicitly below

RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0
ok()  { echo -e "  ${GREEN}[PASS]${NC} $*"; ((PASS++)) || true; }
bad() { echo -e "  ${RED}[FAIL]${NC} $*"; ((FAIL++)) || true; }

TMP="$(mktemp -d)"

echo ""; echo -e "${BOLD}Quality gate + manifest tests${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"

# ── 1. N-fraction maths ───────────────────────────────────────────────────
printf '>x\nACGTACGTACGT\n'  > "${TMP}/clean.fa"
printf '>x\nNNNNNNNNNNNN\n'  > "${TMP}/degen.fa"
printf '>x\nNNNNNNACGT\n'    > "${TMP}/warn.fa"     # 6 N / 10 = 0.60

echo ""; echo -e "${BOLD}1. fasta_n_fraction${NC}"
nf=$(fasta_n_fraction "${TMP}/clean.fa"); awk "BEGIN{exit !(${nf} < 0.01)}" && ok "clean -> ${nf} (~0)" || bad "clean -> ${nf}"
nf=$(fasta_n_fraction "${TMP}/degen.fa"); awk "BEGIN{exit !(${nf} > 0.99)}" && ok "all-N -> ${nf} (~1)" || bad "all-N -> ${nf}"
nf=$(fasta_n_fraction "${TMP}/warn.fa");  awk "BEGIN{exit !(${nf} > 0.59 && ${nf} < 0.61)}" && ok "60%% N -> ${nf}" || bad "60%% N -> ${nf}"

# ── 2. assert_ancestor_quality gating ─────────────────────────────────────
echo ""; echo -e "${BOLD}2. assert_ancestor_quality gate${NC}"
nf=$( assert_ancestor_quality "${TMP}/clean.fa" clean 2>/dev/null ); rc=$?
{ (( rc == 0 )) && [[ -n "${nf}" ]]; } && ok "clean passes (rc=0, nf=${nf})" || bad "clean should pass (rc=${rc})"

( assert_ancestor_quality "${TMP}/degen.fa" degen ) >/dev/null 2>&1
(( $? != 0 )) && ok "all-N ancestor REFUSED (fail-closed)" || bad "all-N ancestor should be refused"

# warn threshold: 0.60 N is > warn(0.50) but < max(0.90) -> passes but warns
nf=$( assert_ancestor_quality "${TMP}/warn.fa" warn 2>/dev/null ); rc=$?
(( rc == 0 )) && ok "60%% N passes with warning (rc=0)" || bad "60%% N should pass+warn (rc=${rc})"

# override: max=1 disables the hard gate even for all-N
( HOMOPAN_MAX_N_FRAC=1 assert_ancestor_quality "${TMP}/degen.fa" degen ) >/dev/null 2>&1
(( $? == 0 )) && ok "HOMOPAN_MAX_N_FRAC=1 override allows all-N" || bad "override should allow all-N"

# ── 3. per-run manifest ───────────────────────────────────────────────────
echo ""; echo -e "${BOLD}3. write_run_manifest${NC}"
run_in_container() { echo "cactus 9.1.2-stub"; }   # avoid real apptainer
SIF="${TMP}/fake.sif"; : > "${SIF}"                # cheap digest source
printf 'homo_sapiens\tdeadbeef\t123\n' > "${QC_DIR}/genome_checksums.tsv"
printf 'Anc_HomoPan\tcafef00d\t1000\t0.0100\n'     > "${QC_DIR}/ancestor_checksums.tsv"
write_run_manifest >/dev/null 2>&1
MAN="${QC_DIR}/manifests/${RUN_ID}.json"
[[ -f "${MAN}" ]] && ok "manifest emitted ($(basename "${MAN}"))" || bad "manifest not written"
# jq is routed to the capable build by config.sh (function); it reads stdin fine.
jq -e . < "${MAN}" >/dev/null 2>&1 && ok "manifest is valid JSON" || bad "manifest invalid JSON"
sch=$(jq -r '.schema' < "${MAN}" 2>/dev/null)
[[ "${sch}" == "2" ]] && ok "manifest schema=2" || bad "schema mismatch: ${sch}"
rid=$(jq -r '.meta.run_id' < "${MAN}" 2>/dev/null)
[[ "${rid}" == "${RUN_ID}" ]] && ok "meta.run_id matches (${rid})" || bad "run_id mismatch: ${rid}"
jq -e '.repro.sif_sha256 and .repro.cactus_seed and .repro.outputs.ancestors."Anc_HomoPan".n_fraction=="0.0100"' < "${MAN}" >/dev/null 2>&1 \
  && ok "repro block carries sif+seed+ancestor n_fraction" || bad "repro block missing expected fields"
rs=$(jq -r '.repro_sha256' < "${MAN}" 2>/dev/null)
[[ "${rs}" =~ ^[0-9a-f]{64}$ ]] && ok "repro_sha256 present (${rs:0:12}...)" || bad "repro_sha256 missing/invalid"
jq -e '(.meta|has("timestamp")) and (.meta|has("repro")|not)' < "${MAN}" >/dev/null 2>&1 \
  && ok "meta holds timestamp; repro kept out of meta (deterministic separation)" || bad "meta/repro separation broken"

# ── cleanup ───────────────────────────────────────────────────────────────
rm -rf "${TMP}" "${SRC_ROOT}/runs/${HOMOPAN_RUN_NS}" 2>/dev/null

echo ""
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD}  Results: ${PASS} passed, ${FAIL} failed${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"
(( FAIL == 0 )) || { echo -e "${RED}${BOLD}TESTS FAILED${NC}"; exit 1; }
echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"; exit 0
