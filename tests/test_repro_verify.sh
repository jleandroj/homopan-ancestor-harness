#!/usr/bin/env bash
# test_repro_verify.sh -- DETERMINISM proof (CI-blocking): two test-path runs on
# SYNTHETIC genomes with a deterministic mock toolchain produce BIT-IDENTICAL
# artifacts. Proves the harness injects no non-determinism (no clock/randomness
# in artifacts) and feeds identical inputs to both runs. Real-Cactus bit-identity
# is MEASURED (not asserted) by scripts/repro_verify.sh -- see REPRODUCIBILITY.md.
# Self-contained + fast (synthetic 3 kb genomes); does NOT touch real genomes.
set -uo pipefail
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0
ok()  { echo -e "  ${GREEN}[PASS]${NC} $*"; ((PASS++)) || true; }
bad() { echo -e "  ${RED}[FAIL]${NC} $*"; ((FAIL++)) || true; }
command -v samtools >/dev/null 2>&1 || { echo -e "  ${YELLOW}[SKIP]${NC} host samtools missing"; exit 0; }

SPECIES=(homo_sapiens pan_paniscus pan_troglodytes gorilla_gorilla_gorilla pongo_abelii)
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/scripts" "${TMP}/genomes" "${TMP}/bin" "${TMP}/repro"
cp "${SRC_ROOT}/scripts/"*.sh "${TMP}/scripts/"
mkdir -p "${TMP}/scripts/lib"; cp "${SRC_ROOT}/scripts/lib/"*.sh "${TMP}/scripts/lib/" 2>/dev/null || true
[[ -f "${SRC_ROOT}/repro/toolchain.lock" ]] && cp "${SRC_ROOT}/repro/toolchain.lock" "${TMP}/repro/"
printf 'species\taccession\n' > "${TMP}/accessions.tsv"
: > "${TMP}/cactus_v3.0.1.sif"

# Synthetic genomes (identical content for both runs -> identical inputs).
for sp in "${SPECIES[@]}"; do
  { echo ">chr_${sp}"; yes "ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTAC" | head -n 40; } > "${TMP}/genomes/${sp}.fa"
  samtools faidx "${TMP}/genomes/${sp}.fa" 2>/dev/null
done

# Deterministic mock toolchain: cactus output is a PURE function of the seqFile
# (its sha + sorted member-FASTA shas) -> identical inputs => identical HAL.
cat > "${TMP}/bin/apptainer" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "apptainer version mock"; exit 0; }
a=("$@"); [[ "${a[0]:-}" == "exec" ]] && a=("${a[@]:1}")
i=0; while (( i < ${#a[@]} )); do case "${a[$i]}" in
  --bind) i=$((i+2));; *.sif) i=$((i+1)); break;; --*) i=$((i+1));; *) break;; esac; done
tool="${a[$i]:-}"; rest=("${a[@]:$((i+1))}")
case "$tool" in
  which) echo "/usr/local/bin/${rest[0]:-x}"; exit 0;;
  cactus)
    for x in "${rest[@]}"; do [[ "$x" == "--version" ]] && { echo "9.1.2-mock"; exit 0; }; [[ "$x" == "--help" ]] && { echo "no seed"; exit 0; }; done
    pos=(); j=0; while (( j < ${#rest[@]} )); do case "${rest[$j]}" in
      --binariesMode|--batchSystem|--realTimeLogging|--seed|--retryCount) j=$((j+2));;
      --*) j=$((j+1));; *) pos+=("${rest[$j]}"); j=$((j+1));; esac; done
    sf="${pos[1]:-}"; hal="${pos[2]:-}"; [[ -n "$hal" ]] || { echo "no hal" >&2; exit 1; }
    mkdir -p "$(dirname "$hal")"
    # HAL = sorted sha256 of each member FASTA's CONTENT (input-derived,
    # namespace-invariant). cactus CLI: <jobStore> <seqFile> <outputHal>.
    { echo "MOCK-HAL deterministic"
      awk 'NF>=2{print $2}' "$sf" 2>/dev/null | while read -r p; do [[ -f "$p" ]] && sha256sum "$p" | cut -d' ' -f1; done | sort; } > "$hal"
    exit 0;;
  halValidate) echo "File valid"; exit 0;;
  halStats) case "${rest[0]:-}" in
      --version) echo "v2.2-mock";;
      --genomes) echo "homo_sapiens, pan_paniscus, pan_troglodytes, gorilla_gorilla_gorilla, pongo_abelii, Anc_HomoPan, Pan, Homininae, Root";;
      --tree) echo "(((homo_sapiens,(pan_paniscus,pan_troglodytes)Pan)Anc_HomoPan,gorilla_gorilla_gorilla)Homininae,pongo_abelii)Root;";;
      *) echo "mock halStats";; esac; exit 0;;
  hal2fasta) printf '>%s\nACGTACGTACGTACGTACGTACGTACGTACGT\n' "${rest[1]:-anc}"; exit 0;;
  *) exit 0;;
esac
STUB
chmod +x "${TMP}/bin/apptainer"

echo ""; echo -e "${BOLD}repro determinism: two synthetic test runs (mock)${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"

run() {  # <ns>
  PATH="${TMP}/bin:${PATH}" HOMOPAN_RUN_NS="$1" CACTUS_SEED=42 CACTUS_TIMEOUT=60 \
    HOMOPAN_SKIP_PREFLIGHT=1 HOMOPAN_IGNORE_TOOLCHAIN_LOCK=1 HOMOPAN_SANDBOX_COMPUTE=0 \
    bash "${TMP}/scripts/run_all_test.sh" >"${TMP}/$1.log" 2>&1
}
run reproA && ok "run A completed" || { bad "run A failed"; tail -15 "${TMP}/reproA.log"|sed 's/^/      /'; }
run reproB && ok "run B completed" || { bad "run B failed"; tail -15 "${TMP}/reproB.log"|sed 's/^/      /'; }

for rel in results/test/primates.test.hal results/ancestors/Anc_HomoPan.test.fa; do
  fa="${TMP}/runs/reproA/${rel}"; fb="${TMP}/runs/reproB/${rel}"
  if [[ -f "${fa}" && -f "${fb}" ]]; then
    sa=$(sha256sum "${fa}"|cut -d' ' -f1); sb=$(sha256sum "${fb}"|cut -d' ' -f1)
    [[ "${sa}" == "${sb}" ]] && ok "BIT-IDENTICAL ${rel} (${sa:0:16}...)" || bad "DIVERGENT ${rel}: ${sa:0:12} vs ${sb:0:12}"
  else
    bad "missing artifact ${rel} (A:$([[ -f $fa ]]&&echo y||echo n) B:$([[ -f $fb ]]&&echo y||echo n))"
  fi
done

# repro_sha256 from the two manifests must also be identical (same inputs).
MA="${TMP}/runs/reproA/qc/manifests"; MB="${TMP}/runs/reproB/qc/manifests"
ra=$(cat "${MA}"/*.json 2>/dev/null | "${HOMOPAN_JQ:-jq}" -rs '.[0].repro_sha256 // "a"' 2>/dev/null)
rb=$(cat "${MB}"/*.json 2>/dev/null | "${HOMOPAN_JQ:-jq}" -rs '.[0].repro_sha256 // "b"' 2>/dev/null)
[[ -n "${ra}" && "${ra}" == "${rb}" ]] && ok "manifest repro_sha256 identical (${ra:0:16}...)" || bad "repro_sha256 differ (${ra:0:12} vs ${rb:0:12})"

echo ""
echo -e "${BOLD}  Results: ${PASS} passed, ${FAIL} failed${NC}"
(( FAIL == 0 )) || { echo -e "${RED}${BOLD}TESTS FAILED${NC}"; exit 1; }
echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"; exit 0
