#!/usr/bin/env bash
# repro_verify.sh -- prove (or refute, honestly) determinism of the TEST-path
# compute. Runs the test pipeline TWICE in two fresh namespaces with the SAME
# CACTUS_SEED and compares the sha256 of the produced artifacts.
#
# Modes:
#   (default)      real toolchain. Bit-identical => PASS. If Cactus is
#                  intrinsically non-deterministic, report the diverging
#                  artifact and fall back to a documented EQUIVALENCE metric
#                  (halStats identical + ancestral-sequence identity >= threshold).
#   --mock         deterministic stub toolchain (cactus output is a pure function
#                  of the seqFile). Proves the HARNESS injects no non-determinism
#                  and feeds identical inputs to both runs. Fast; used by CI
#                  (tests/test_repro_verify.sh). REQUIRES host samtools.
#   --write-lock   (re)generate repro/toolchain.lock from the live host and exit.
#
# Caveat: the 1 Mb test path is a TECHNICAL determinism check, NOT biology.
set -uo pipefail
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SRC_ROOT}/scripts/config.sh"

IDENTITY_THRESHOLD="${HOMOPAN_REPRO_IDENTITY:-0.999}"   # ancestral-seq identity floor

# ── --write-lock : regenerate the toolchain lock from the live host ────────
if [[ "${1:-}" == "--write-lock" ]]; then
  lock="${SRC_ROOT}/repro/toolchain.lock"; mkdir -p "$(dirname "${lock}")"
  {
    echo "# repro/toolchain.lock -- regenerated $(date -Iseconds)"
    echo "# strict_* = fail-closed (output-determining); audit_* = warn only."
    echo "# Override strict with HOMOPAN_IGNORE_TOOLCHAIN_LOCK=1."
    echo "schema=1"
    echo "strict_sif_sha256=$(sha256sum "$(realpath -m "${SIF}")" 2>/dev/null | cut -d' ' -f1)"
    echo "strict_cactus=$(cactus_version)"
    echo "strict_samtools=$(samtools --version 2>/dev/null | head -1)"
    echo "strict_apptainer=$(apptainer --version 2>/dev/null)"
    echo "audit_bedtools=$(bedtools --version 2>/dev/null)"
    echo "audit_jq=$(jq --version 2>/dev/null)"
    echo "audit_bash=${BASH_VERSION}"
    echo "audit_kernel=$(uname -r)"
  } > "${lock}"
  log_ok "Wrote $(sanitize_path "${lock}")"
  exit 0
fi

MOCK=0; [[ "${1:-}" == "--mock" ]] && MOCK=1
SEED="${CACTUS_SEED-0}"
TAG="$$"
NS_A="repro_a_${TAG}"; NS_B="repro_b_${TAG}"
STUB_DIR=""

cleanup() {
  rm -rf "${SRC_ROOT}/runs/${NS_A}" "${SRC_ROOT}/runs/${NS_B}" 2>/dev/null
  [[ -n "${STUB_DIR}" ]] && rm -rf "${STUB_DIR}" 2>/dev/null
}
trap cleanup EXIT

# ── Deterministic mock toolchain (only for --mock) ─────────────────────────
# cactus output = sha256 of the seqFile + sorted member FASTA shas => a pure,
# input-only function. If the harness fed identical inputs to both runs and
# injected no clock/randomness, the two HALs are byte-identical.
make_mock() {
  STUB_DIR="$(mktemp -d)"
  cat > "${STUB_DIR}/apptainer" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "apptainer version mock"; exit 0; }
a=("$@"); [[ "${a[0]:-}" == "exec" ]] && a=("${a[@]:1}")
i=0; while (( i < ${#a[@]} )); do case "${a[$i]}" in
  --bind) i=$((i+2));; *.sif) i=$((i+1)); break;; --*) i=$((i+1));; *) break;; esac; done
tool="${a[$i]:-}"; rest=("${a[@]:$((i+1))}")
case "$tool" in
  which) echo "/usr/local/bin/${rest[0]:-x}"; exit 0;;
  cactus)
    for x in "${rest[@]}"; do [[ "$x" == "--version" ]] && { echo "9.1.2-mock"; exit 0; }; [[ "$x" == "--help" ]] && { echo "no seed flag"; exit 0; }; done
    pos=(); j=0; while (( j < ${#rest[@]} )); do case "${rest[$j]}" in
      --binariesMode|--batchSystem|--realTimeLogging|--seed|--retryCount) j=$((j+2));;
      --*) j=$((j+1));; *) pos+=("${rest[$j]}"); j=$((j+1));; esac; done
    seqfile="${pos[1]:-}"; hal="${pos[2]:-}"; [[ -n "$hal" ]] || { echo "no hal" >&2; exit 1; }
    mkdir -p "$(dirname "$hal")"
    # HAL = sorted sha256 of each member FASTA's CONTENT (input-derived,
    # namespace-invariant). cactus CLI: <jobStore> <seqFile> <outputHal>.
    { echo "MOCK-HAL deterministic"
      awk 'NF>=2{print $2}' "$seqfile" 2>/dev/null | while read -r p; do
        [[ -f "$p" ]] && sha256sum "$p" | cut -d' ' -f1; done | sort; } > "$hal"
    exit 0;;
  halValidate) echo "File valid"; exit 0;;
  halStats) case "${rest[0]:-}" in
      --version) echo "v2.2-mock";;
      --genomes) echo "homo_sapiens, pan_paniscus, pan_troglodytes, gorilla_gorilla_gorilla, pongo_abelii, Anc_HomoPan";;
      *) echo "mock halStats";; esac; exit 0;;
  hal2fasta) printf '>%s\nACGTACGTACGTACGTACGTACGTACGTACGT\n' "${rest[1]:-anc}"; exit 0;;
  *) exit 0;;
esac
STUB
  chmod +x "${STUB_DIR}/apptainer"
}

run_once() {  # <ns>
  local ns="$1" log; log="$(mktemp)"
  local env_pre=(HOMOPAN_RUN_NS="${ns}" CACTUS_SEED="${SEED}" HOMOPAN_SKIP_PREFLIGHT=1 HOMOPAN_IGNORE_TOOLCHAIN_LOCK=1)
  if (( MOCK )); then
    if PATH="${STUB_DIR}:${PATH}" CACTUS_TIMEOUT=120 "${env_pre[@]}" \
       bash "${SRC_ROOT}/scripts/run_all_test.sh" >"${log}" 2>&1; then :; else
      log_error "run (${ns}) failed:"; tail -20 "${log}"; rm -f "${log}"; return 1; fi
  else
    if "${env_pre[@]}" bash "${SRC_ROOT}/scripts/run_all_test.sh" >"${log}" 2>&1; then :; else
      log_error "run (${ns}) failed:"; tail -20 "${log}"; rm -f "${log}"; return 1; fi
  fi
  rm -f "${log}"
}

artifact() { echo "${SRC_ROOT}/runs/$1/$2"; }
sha_of() { [[ -f "$1" ]] && sha256sum "$1" | cut -d' ' -f1 || echo "MISSING"; }

# ── Run twice ──────────────────────────────────────────────────────────────
(( MOCK )) && make_mock
log_step "repro_verify: two test runs (seed=${SEED}, mode=$([[ $MOCK == 1 ]] && echo mock || echo real))"
run_once "${NS_A}" || exit 1
run_once "${NS_B}" || exit 1

# ── Compare artifacts ────────────────────────────────────────────────────────
REL_HAL="results/test/primates.test.hal"
REL_ANC="results/ancestors/Anc_HomoPan.test.fa"
rc=0
for rel in "${REL_HAL}" "${REL_ANC}"; do
  fa="$(artifact "${NS_A}" "${rel}")"; fb="$(artifact "${NS_B}" "${rel}")"
  [[ -f "${fa}" || -f "${fb}" ]] || { log_info "skip (${rel}): not produced in test path"; continue; }
  sa="$(sha_of "${fa}")"; sb="$(sha_of "${fb}")"
  if [[ "${sa}" == "${sb}" && "${sa}" != "MISSING" ]]; then
    log_ok "BIT-IDENTICAL ${rel}  sha256=${sa:0:16}..."
  else
    log_warn "DIVERGENT ${rel}: A=${sa:0:16}... B=${sb:0:16}..."
    rc=1
    # Documented equivalence fallback (real Cactus may be non-bit-deterministic).
    if [[ "${rel}" == "${REL_ANC}" && -f "${fa}" && -f "${fb}" ]]; then
      id=$(awk '
        function seq(f,  s,l){s="";while((getline l < f)>0){if(l!~/^>/)s=s l}return s}
        BEGIN{a=seq(ARGV[1]);b=seq(ARGV[2]);n=length(a);if(length(b)<n)n=length(b);
              if(n==0){print "0";exit} m=0;for(i=1;i<=n;i++)if(substr(a,i,1)==substr(b,i,1))m++;
              printf "%.6f", m/n}' "${fa}" "${fb}")
      if awk "BEGIN{exit !(${id} >= ${IDENTITY_THRESHOLD})}"; then
        log_warn "  -> ancestral identity ${id} >= ${IDENTITY_THRESHOLD}: EQUIVALENT (not bit-identical)"
      else
        log_error "  -> ancestral identity ${id} < ${IDENTITY_THRESHOLD}: NOT equivalent"
      fi
    fi
  fi
done

echo ""
if (( rc == 0 )); then
  log_ok "REPRO VERIFIED: test artifacts are BIT-IDENTICAL across two runs (seed=${SEED})."
  echo "  Deterministic & verifiable. (1 Mb test = technical only, not biological.)"
else
  log_warn "REPRO: artifacts NOT bit-identical. See divergence + equivalence verdict above."
  echo "  If real Cactus, this is the honest finding: document the non-determinism;"
  echo "  bit-identity is only guaranteed where proven (mock/CI). Ancestors are inferred."
fi
exit "${rc}"
