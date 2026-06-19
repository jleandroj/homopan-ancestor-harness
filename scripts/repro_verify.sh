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
      --genomes) echo "homo_sapiens, pan_paniscus, pan_troglodytes, gorilla_gorilla_gorilla, pongo_abelii, Anc_HomoPan, Pan, Homininae, Root";;
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
    # Stub container -> sandboxing a stub is meaningless; opt out so --mock works
    # on hosts without unprivileged userns (real mode keeps fail-closed default).
    if PATH="${STUB_DIR}:${PATH}" CACTUS_TIMEOUT=120 HOMOPAN_SANDBOX_COMPUTE=0 env "${env_pre[@]}" \
       bash "${SRC_ROOT}/scripts/run_all_test.sh" >"${log}" 2>&1; then :; else
      log_error "run (${ns}) failed:"; tail -20 "${log}"; rm -f "${log}"; return 1; fi
  else
    if env "${env_pre[@]}" bash "${SRC_ROOT}/scripts/run_all_test.sh" >"${log}" 2>&1; then :; else
      log_error "run (${ns}) failed:"; tail -20 "${log}"; rm -f "${log}"; return 1; fi
  fi
  rm -f "${log}"
}

artifact() { echo "${SRC_ROOT}/runs/$1/$2"; }
sha_of() { [[ -f "$1" ]] && sha256sum "$1" | cut -d' ' -f1 || echo "MISSING"; }

# Alignment-based sequence identity (coordinate/length/orientation tolerant),
# replacing the old naive positional char compare which is meaningless when the
# two sequences have different lengths/coordinates. Uses the container's
# minimap2 (gap-compressed identity over aligned blocks + aligned coverage).
# Echoes "<identity> <coverage>" in [0,1]; "0 0" if nothing aligns; "NA NA" if
# the aligner is unavailable. MOCK mode skips it (no real aligner needed).
seq_identity() {   # <faA> <faB>
  local a="$1" b="$2" paf
  command -v apptainer >/dev/null 2>&1 || { echo "NA NA"; return 0; }
  [[ -f "${SIF:-}" ]] || { echo "NA NA"; return 0; }
  paf=$(apptainer exec --bind "${SRC_ROOT}" "${SIF}" \
        minimap2 -cx asm5 --secondary=no "$a" "$b" 2>/dev/null) || { echo "NA NA"; return 0; }
  [[ -z "${paf}" ]] && { echo "0 0"; return 0; }
  printf '%s\n' "${paf}" | awk '
    { nm+=$10; bl+=$11; if($2>qlen)qlen=$2; aq+=($4-$3) }
    END{ id=(bl>0)?nm/bl:0; cov=(qlen>0)?aq/qlen:0; printf "%.6f %.6f", id, cov }'
}

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
    # Alignment-based (minimap2): equivalent only if BOTH identity AND aligned
    # coverage clear the threshold -- high identity over a tiny aligned fraction
    # is NOT equivalence.
    if [[ "${rel}" == "${REL_ANC}" && -f "${fa}" && -f "${fb}" ]]; then
      read -r id cov < <(seq_identity "${fa}" "${fb}")
      if [[ "${id}" == "NA" ]]; then
        log_warn "  -> equivalence metric unavailable (no minimap2/container); reporting bytes only"
      else
        log_info "  -> alignment metric: identity=${id} coverage=${cov} (minimap2 asm5, gap-compressed)"
        if awk "BEGIN{exit !(${id} >= ${IDENTITY_THRESHOLD} && ${cov} >= ${IDENTITY_THRESHOLD})}"; then
          log_warn "  -> EQUIVALENT by alignment (id ${id}, cov ${cov} >= ${IDENTITY_THRESHOLD}), not bit-identical"
        else
          log_error "  -> NOT equivalent (id ${id}, cov ${cov} vs threshold ${IDENTITY_THRESHOLD})"
        fi
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
