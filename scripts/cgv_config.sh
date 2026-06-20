#!/usr/bin/env bash
# cgv_config.sh -- Shared library for the CGV replication sub-harness.
#
# Goal: independently re-derive NCBI's Comparative Genome Viewer assembly-vs-
# assembly alignment (Homo sapiens GCF_009914755.1  x  Pan paniscus
# GCF_029289425.2) from raw DNA, with THREE aligners (minimap2, LASTZ, MashMap),
# and benchmark each against NCBI's official ASMASM GFF as ground truth.
#
# This sub-pipeline is SELF-CONTAINED: it does not touch the Cactus/ancestor
# pipeline or any contract file. It mirrors the repo conventions (numbered
# NN_*.sh steps, run_all_* orchestrators, input-hash idempotency markers under
# targets/, logging to stderr, sandbox + egress reuse) without depending on
# scripts/config.sh (which is Cactus-specific).
#
# Source from every step:  source "$(dirname "${BASH_SOURCE[0]}")/cgv_config.sh"
set -euo pipefail

# ── Project root (derived from BASH_SOURCE, never hardcoded) ───────────────
CGV_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${CGV_SCRIPTS_DIR}/.." && pwd)"

# ── Aligner toolchain (dedicated conda env, isolated from the host) ────────
CGV_ENV="${CGV_ENV:-cgv_align}"
# Resolve the env's bin dir without forcing a conda activate. Prepending it to
# PATH only adds the aligners + datasets; samtools/bedtools/python stay host.
for _cand in \
    "${CGV_ENV_BIN:-}" \
    "${HOME}/miniconda3/envs/${CGV_ENV}/bin" \
    "${HOME}/anaconda3/envs/${CGV_ENV}/bin" \
    "${CONDA_PREFIX:-}/envs/${CGV_ENV}/bin"; do
  if [[ -n "${_cand}" && -d "${_cand}" ]]; then export CGV_ENV_BIN="${_cand}"; break; fi
done
unset _cand
if [[ -n "${CGV_ENV_BIN:-}" ]]; then export PATH="${CGV_ENV_BIN}:${PATH}"; fi

# ── Accessions (the two assemblies NCBI CGV aligned) ──────────────────────
# HUMAN  : T2T-CHM13v2.0, RefSeq  -> contigs NC_060925.1 .. NC_060948.1
# BONOBO : mPanPan1.1,    RefSeq  -> contigs NC_073250.2 .. (and NC_085926.1 etc.)
HUMAN_ACC="${HUMAN_ACC:-GCF_009914755.1}"
BONOBO_ACC="${BONOBO_ACC:-GCF_029289425.2}"

# ── Run mode (test = one chromosome pair; full = whole genome) ─────────────
# The contract forbids assuming the mode -- the orchestrators set it explicitly.
CGV_MODE="${CGV_MODE:-test}"
case "${CGV_MODE}" in test|full) ;; *) echo "cgv_config: invalid CGV_MODE='${CGV_MODE}' (test|full)" >&2; exit 1 ;; esac

# Test mode aligns a small homologous BOX -- a window on BOTH genomes (not whole
# chromosomes). minimap2 parallelizes across query sequences, so a single
# whole-chromosome query (one 228 Mb sequence) chains single-threaded and is
# hopelessly slow; a ~10 Mb x 10 Mb box keeps the query small and finishes in
# seconds. cgv_02 picks the densest box from the ground truth; the box edges are
# recorded in region.tsv and added back as offsets so coordinates stay in
# chromosome space (comparable to the truth).
CGV_TEST_WINDOW_MB="${CGV_TEST_WINDOW_MB:-10}"
CGV_TEST_WINDOW_BP=$(( CGV_TEST_WINDOW_MB * 1000000 ))

# ── Ground truth (official NCBI ASMASM GFF, already downloaded) ────────────
TRUTH_GFF="${CGV_TRUTH_GFF:-${PROJECT_ROOT}/GCF_029289425.2-GCF_009914755.1.gff}"
CGV_TRUTH_DIR="${PROJECT_ROOT}/cgv_truth"
TRUTH_BLOCKS="${CGV_TRUTH_DIR}/truth_blocks.tsv"   # normalized: aligner-agnostic schema

# ── Genomes (downloaded; full assemblies and per-mode extracts) ───────────
CGV_GENOMES_DIR="${PROJECT_ROOT}/cgv_genomes"
HUMAN_FA="${CGV_GENOMES_DIR}/human.fa"             # full assembly (download)
BONOBO_FA="${CGV_GENOMES_DIR}/bonobo.fa"
CGV_TEST_DIR="${CGV_GENOMES_DIR}/test"
HUMAN_TEST_FA="${CGV_TEST_DIR}/human.test.fa"      # one chromosome (test mode)
BONOBO_TEST_FA="${CGV_TEST_DIR}/bonobo.test.fa"
REGION_FILE="${CGV_TEST_DIR}/region.tsv"           # chosen (human_chr, bonobo_chr) pair

# Active FASTAs for the current mode (what the aligner steps consume).
if [[ "${CGV_MODE}" == "test" ]]; then
  HUMAN_ACTIVE="${HUMAN_TEST_FA}"; BONOBO_ACTIVE="${BONOBO_TEST_FA}"
else
  HUMAN_ACTIVE="${HUMAN_FA}";      BONOBO_ACTIVE="${BONOBO_FA}"
fi

# ── Outputs (namespaced by mode) ──────────────────────────────────────────
CGV_RESULTS="${PROJECT_ROOT}/results/cgv/${CGV_MODE}"
CGV_BLOCKS_DIR="${CGV_RESULTS}/blocks"             # <aligner>.blocks.tsv (+ truth)
CGV_FIGS_DIR="${CGV_RESULTS}/figures"
CGV_BENCHMARK="${CGV_RESULTS}/benchmark.tsv"
CGV_REPORT="${CGV_RESULTS}/report.md"
CGV_MANIFEST="${CGV_RESULTS}/manifest.json"

# ── State (mirror the repo's targets/logs layout) ─────────────────────────
TARGETS_DIR="${PROJECT_ROOT}/targets"
LOGS_DIR="${PROJECT_ROOT}/logs"

# ── Aligners under test ────────────────────────────────────────────────────
CGV_ALIGNERS=(minimap2 lastz mashmap)

# ── Sandbox / egress reuse (boundary scripts owned by the contract) ───────
SANDBOX_RUN="${CGV_SCRIPTS_DIR}/sandbox_run.sh"
# Aligner steps are CPU-only on LOCAL data and need NO network. They are trusted
# bioconda binaries, so sandboxing is OPT-IN (CGV_SANDBOX=1) rather than the
# fail-closed default the Cactus compute uses. The download step is the only one
# that needs egress, and it goes to NCBI (already in egress_allowlist.txt).
CGV_SANDBOX="${CGV_SANDBOX:-0}"

# ── Colors / logging (to stderr; stdout stays clean for captured data) ────
if [[ -t 2 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[1;33m'
  C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m'; C_NC=$'\033[0m'
else
  C_RED=; C_GRN=; C_YLW=; C_BLU=; C_BLD=; C_NC=
fi
_cgv_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { echo "${C_BLU}[$(_cgv_ts)]${C_NC} ${C_BLD}INFO${C_NC}  $*" >&2; }
log_ok()    { echo "${C_GRN}[$(_cgv_ts)]${C_NC} ${C_GRN}OK${C_NC}    $*" >&2; }
log_warn()  { echo "${C_YLW}[$(_cgv_ts)]${C_NC} ${C_YLW}WARN${C_NC}  $*" >&2; }
log_error() { echo "${C_RED}[$(_cgv_ts)]${C_NC} ${C_RED}ERROR${C_NC} $*" >&2; }
log_step()  { echo "${C_BLU}[$(_cgv_ts)]${C_NC} ${C_BLD}STEP${C_NC}  $*" >&2; }
die() { log_error "$@"; exit 1; }

cgv_banner() {
  echo "" >&2
  echo "${C_BLD}========================================${C_NC}" >&2
  echo "${C_BLD}  $1${C_NC}" >&2
  echo "${C_BLD}  mode=${CGV_MODE}  $(date)${C_NC}" >&2
  echo "${C_BLD}========================================${C_NC}" >&2
}

# ── Directory bootstrap ────────────────────────────────────────────────────
cgv_ensure_dirs() {
  mkdir -p "${CGV_TRUTH_DIR}" "${CGV_GENOMES_DIR}" "${CGV_TEST_DIR}" \
           "${CGV_RESULTS}" "${CGV_BLOCKS_DIR}" "${CGV_FIGS_DIR}" \
           "${TARGETS_DIR}" "${LOGS_DIR}"
}

# ── Idempotency markers (input-hash bound) ────────────────────────────────
# A step is "done" only if its marker exists AND the fingerprint of its declared
# inputs is unchanged. Mirrors scripts/config.sh semantics but with CGV-local
# step declarations. Markers are namespaced by mode so test/full never collide.
_CGV_FP_MAX=$((50 * 1024 * 1024))   # 50 MB: full hash below, sampled hash above
_cgv_fingerprint() {
  local f="$1" sz
  [[ -e "$f" ]] || { printf '%s:MISSING\n' "$f"; return; }
  sz=$(stat -c %s "$f" 2>/dev/null || wc -c < "$f" 2>/dev/null || echo 0)
  if (( sz < _CGV_FP_MAX )); then
    printf '%s:%s\n' "$f" "$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"
  else
    local sample
    sample=$( { head -c 1048576 "$f"; tail -c 1048576 "$f"; } 2>/dev/null | sha256sum | cut -d' ' -f1)
    printf '%s:%s:%s\n' "$f" "$sz" "${sample}"
  fi
}

# Declared inputs per step: file paths and/or literal 'lit:' tokens.
_cgv_step_inputs() {
  case "$1" in
    cgv_01_normalize_truth)  printf '%s\n' "${TRUTH_GFF}" ;;
    cgv_02_select_region)    printf '%s\n' "${TRUTH_BLOCKS}" "lit:window=${CGV_TEST_WINDOW_BP}" "lit:hchr=${CGV_TEST_HUMAN_CHR:-auto}" "lit:bchr=${CGV_TEST_BONOBO_CHR:-auto}" ;;
    cgv_10_align_minimap2)   printf '%s\n' "${HUMAN_ACTIVE}" "${BONOBO_ACTIVE}" "lit:mode=${CGV_MODE}" ;;
    cgv_11_align_lastz)      printf '%s\n' "${HUMAN_ACTIVE}" "${BONOBO_ACTIVE}" "lit:mode=${CGV_MODE}" ;;
    cgv_12_align_mashmap)    printf '%s\n' "${HUMAN_ACTIVE}" "${BONOBO_ACTIVE}" "lit:mode=${CGV_MODE}" ;;
    *) : ;;
  esac
}
_cgv_inputs_hash() {
  local item manifest=""
  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    if [[ "$item" == lit:* ]]; then manifest+="${item}"$'\n'
    else manifest+="$(_cgv_fingerprint "$item")"$'\n'; fi
  done < <(_cgv_step_inputs "$1")
  [[ -z "$manifest" ]] && return 0
  printf '%s' "$manifest" | sha256sum | cut -d' ' -f1
}
_cgv_marker() { echo "${TARGETS_DIR}/${1}.${CGV_MODE}.done"; }

cgv_mark_done() {
  local step="$1" ih marker tmp
  ih="$(_cgv_inputs_hash "$step")"
  marker="$(_cgv_marker "$step")"
  tmp="$(mktemp "${marker}.XXXXXX.tmp")"
  {
    echo "schema=1"
    echo "timestamp=$(date -Iseconds)"
    echo "mode=${CGV_MODE}"
    echo "inputs_sha256=${ih:-none}"
  } > "${tmp}"
  sync "${tmp}" 2>/dev/null || true
  mv -f "${tmp}" "${marker}"
  log_ok "Step '${step}' (${CGV_MODE}) marked done${ih:+ (inputs ${ih:0:12}...)}"
}
cgv_is_done() {
  local step="$1" marker expected stored
  marker="$(_cgv_marker "$step")"
  [[ -f "$marker" ]] || return 1
  expected="$(_cgv_inputs_hash "$step")"; [[ -z "$expected" ]] && expected="none"
  stored="$(grep -E '^inputs_sha256=' "$marker" 2>/dev/null | head -1 | cut -d= -f2)"
  [[ -n "$stored" && "$stored" == "$expected" ]]
}

# ── Sandbox wrapper for aligner steps (opt-in) ─────────────────────────────
# Runs an aligner command, optionally through the contract's bubblewrap sandbox
# (no network), binding the genomes + results dirs read-write. The aligner's
# stdout (PAF / blocks) is preserved verbatim for redirection by the caller.
cgv_run() {
  if [[ "${CGV_SANDBOX}" == "1" && -x "${SANDBOX_RUN}" ]]; then
    HOMOPAN_EXTRA_BINDS="${CGV_GENOMES_DIR} ${CGV_RESULTS} ${CGV_ENV_BIN:-/usr/bin}" \
    HOMOPAN_PASS_ENV="PATH" \
      bash "${SANDBOX_RUN}" "$@"
  else
    "$@"
  fi
}

# ── Tool resolution helpers ────────────────────────────────────────────────
cgv_have() { command -v "$1" >/dev/null 2>&1; }
cgv_require_tool() { cgv_have "$1" || die "Required tool not found on PATH: $1 (env ${CGV_ENV}). Run: bash scripts/cgv_00_check_env.sh"; }

compute_sha256() { sha256sum "$1" | cut -d' ' -f1; }

# Read a field from region.tsv (key in col1 -> value in col2); echo default if absent.
cgv_region_get() {   # <key> [default]
  local k="$1" d="${2:-0}" v
  [[ -s "${REGION_FILE}" ]] || { echo "${d}"; return; }
  v=$(awk -F'\t' -v k="$k" '$1==k{print $2}' "${REGION_FILE}")
  echo "${v:-$d}"
}
cgv_region_window_bp() { cgv_region_get window_bp 0; }

# Test-mode box edges (chromosome coords). 0 / 0 means "not a box" (whole-chr or
# full mode). Aligner steps add the start offsets back so coords are in
# chromosome space; the truth filter restricts to [start,end) on both axes.
CGV_H_OFFSET=$(cgv_region_get human_start 0)
CGV_B_OFFSET=$(cgv_region_get bonobo_start 0)
CGV_H_END=$(cgv_region_get human_end 0)
CGV_B_END=$(cgv_region_get bonobo_end 0)

cgv_ensure_dirs
