#!/usr/bin/env bash
# config.sh -- Shared library for HomoPan Ancestor pipeline
# Source this from every script: source "$(dirname "$0")/config.sh"
# Provides: PROJECT_ROOT, SIF, wrappers, logging, signals, idempotency
set -euo pipefail

# ── Project root (derived from BASH_SOURCE, never hardcoded) ──────────────
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"

# ── Core paths ────────────────────────────────────────────────────────────
GENOMES_DIR="${PROJECT_ROOT}/genomes"
TEST_GENOMES_DIR="${PROJECT_ROOT}/test_genomes"
RESULTS_DIR="${PROJECT_ROOT}/results"
RESULTS_TEST="${RESULTS_DIR}/test"
RESULTS_FULL="${RESULTS_DIR}/full"
RESULTS_ANCESTORS="${RESULTS_DIR}/ancestors"
RESULTS_REGIONS="${RESULTS_DIR}/regions"
RESULTS_REPORTS="${RESULTS_DIR}/reports"
LOGS_DIR="${PROJECT_ROOT}/logs"
QC_DIR="${PROJECT_ROOT}/qc"
TARGETS_DIR="${PROJECT_ROOT}/targets"

# ── Container ─────────────────────────────────────────────────────────────
SIF="${PROJECT_ROOT}/cactus_v3.0.1.sif"
export APPTAINER_CACHEDIR="${PROJECT_ROOT}/apptainer_cache"
export APPTAINER_TMPDIR="${PROJECT_ROOT}/apptainer_tmp"

# ── Biology ───────────────────────────────────────────────────────────────
SPECIES=(homo_sapiens pan_paniscus pan_troglodytes gorilla_gorilla_gorilla pongo_abelii)
ANCESTOR_NODES=(Anc_HomoPan Pan Homininae Root)
# Branch lengths from TimeTree (million years, scaled to substitutions/site approx)
# homo-pan split ~6.7 Mya, pan-pan split ~2.0 Mya, gorilla split ~9.1 Mya, pongo split ~15.2 Mya
NEWICK_TREE='(((homo_sapiens:0.0067,(pan_paniscus:0.002,pan_troglodytes:0.002)Pan:0.0047)Anc_HomoPan:0.0024,gorilla_gorilla_gorilla:0.0091)Homininae:0.0061,pongo_abelii:0.0152)Root;'

# ── Seqfile paths ─────────────────────────────────────────────────────────
SEQFILE_FULL="${PROJECT_ROOT}/primates.seqfile"
SEQFILE_TEST="${PROJECT_ROOT}/primates.test.seqfile"

# ── Result file paths ─────────────────────────────────────────────────────
HAL_TEST="${RESULTS_TEST}/primates.test.hal"
HAL_FULL="${RESULTS_FULL}/primates.full.hal"

# ── Alternate work directory (for disk overflow) ─────────────────────────
# Set HOMOPAN_WORKDIR env var to use an alternate disk (e.g. /mnt/s1)
# Example: HOMOPAN_WORKDIR=/mnt/s1/homopan_work bash scripts/run_all_full.sh
WORK_DIR="${HOMOPAN_WORKDIR:-${PROJECT_ROOT}/work}"
mkdir -p "${WORK_DIR}" 2>/dev/null || true

# ── Jobstore paths ────────────────────────────────────────────────────────
JS_TEST="${WORK_DIR}/js-test"
JS_FULL="${WORK_DIR}/js-full"

# ── Thresholds ────────────────────────────────────────────────────────────
DISK_WARN_GB=200
DISK_FULL_MIN_GB=400
TEST_REGION_LEN=1000000   # 1 Mb

# ── Colors ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()  { echo -e "${BLUE}[$(_ts)]${NC} ${BOLD}INFO${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[$(_ts)]${NC} ${GREEN}OK${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[$(_ts)]${NC} ${YELLOW}WARN${NC}  $*"; }
log_error() { echo -e "${RED}[$(_ts)]${NC} ${RED}ERROR${NC} $*"; }
log_step()  { echo -e "${BLUE}[$(_ts)]${NC} ${BOLD}STEP${NC}  $*"; }

die() { log_error "$@"; exit 1; }

# ── Sanitize paths for logging (redact $HOME) ────────────────────────────
sanitize_path() {
  local p="$1"
  echo "${p//${HOME}/\~}"
}

# ── Portable file mtime (avoids GNU-only stat -c %Y) ─────────────────────
file_mtime_epoch() {
  local f="$1"
  if date -r "$f" +%s 2>/dev/null; then
    return
  fi
  # fallback to stat (GNU)
  stat -c %Y "$f" 2>/dev/null || echo 0
}

# ── Ensure directories exist ─────────────────────────────────────────────
ensure_dirs() {
  mkdir -p "${LOGS_DIR}" "${QC_DIR}" "${TARGETS_DIR}" \
    "${RESULTS_TEST}" "${RESULTS_FULL}" "${RESULTS_ANCESTORS}" \
    "${RESULTS_REGIONS}" "${RESULTS_REPORTS}" \
    "${PROJECT_ROOT}/work"
}

# ── Signal trap ───────────────────────────────────────────────────────────
_cleanup_hooks=()

add_cleanup() { _cleanup_hooks+=("$1"); }

_run_cleanup() {
  local rc=$?
  set +e
  if (( ${#_cleanup_hooks[@]} > 0 )); then
    for hook in "${_cleanup_hooks[@]}"; do
      "$hook" || true
    done
  fi
  if (( rc != 0 )); then
    log_error "Script exited with code ${rc}"
  fi
  exit "$rc"
}

trap _run_cleanup EXIT INT TERM

# ── Idempotency markers (input-hash bound) ───────────────────────────────
# A step counts as "done" only if its marker exists AND the fingerprint of
# its declared inputs matches what was recorded when it completed. Changing a
# tracked input (file content, or a tracked config value) invalidates the
# marker so the step re-runs. This is an idempotency control, NOT a security
# control (no defence against a deliberate same-content forgery).
#
# Fingerprint strategy per file:
#   - small files (< 50 MB): full SHA256 content hash (robust)
#   - large files (genomes, HAL): path:size:mtime (fast; avoids hashing GBs)

_FP_CONTENT_MAX=$((50 * 1024 * 1024))   # 50 MB

_input_fingerprint() {
  local f="$1"
  if [[ ! -e "$f" ]]; then
    printf '%s:MISSING\n' "$f"
    return
  fi
  local sz
  sz=$(stat -c %s "$f" 2>/dev/null || wc -c < "$f" 2>/dev/null || echo 0)
  if (( sz < _FP_CONTENT_MAX )); then
    printf '%s:%s\n' "$f" "$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"
  else
    printf '%s:%s:%s\n' "$f" "$sz" "$(file_mtime_epoch "$f")"
  fi
}

# Declared inputs per step: file paths and/or literal config tokens (prefixed
# 'lit:') whose change must invalidate the step. Empty list => existence-only
# tracking (e.g. environment / QC summary steps that have no stable inputs).
step_inputs() {
  local step="$1"
  case "$step" in
    01_validate_fastas)
      printf '%s\n' "${GENOMES_DIR}"/*.fa "${GENOMES_DIR}"/*.fa.fai "${PROJECT_ROOT}/accessions.tsv" ;;
    02_make_test_fastas)
      printf '%s\n' "${GENOMES_DIR}"/*.fa.fai "lit:TEST_REGION_LEN=${TEST_REGION_LEN}" ;;
    03_make_seqfiles)
      printf '%s\n' "${TEST_GENOMES_DIR}"/*.fa "${GENOMES_DIR}"/*.fa.fai "lit:NEWICK=${NEWICK_TREE}" ;;
    04_run_test_cactus)
      printf '%s\n' "${SEQFILE_TEST}" "lit:NEWICK=${NEWICK_TREE}" ;;
    05_validate_test_hal)
      printf '%s\n' "${HAL_TEST}" ;;
    06_run_full_cactus)
      printf '%s\n' "${SEQFILE_FULL}" "lit:NEWICK=${NEWICK_TREE}" ;;
    07_validate_full_hal)
      printf '%s\n' "${HAL_FULL}" ;;
    08_extract_ancestors)
      printf '%s\n' "${HAL_FULL}" "lit:ANCESTORS=${ANCESTOR_NODES[*]}" ;;
    09_make_report)
      printf '%s\n' "${HAL_FULL}" "${RESULTS_ANCESTORS}"/*.fa ;;
    *)
      : ;;  # no declared inputs -> existence-only
  esac
}

# Hash a step's input manifest. Echoes empty string when no inputs declared.
_step_inputs_hash() {
  local step="$1" item manifest=""
  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    if [[ "$item" == lit:* ]]; then
      manifest+="${item}"$'\n'
    else
      manifest+="$(_input_fingerprint "$item")"$'\n'
    fi
  done < <(step_inputs "$step")
  [[ -z "$manifest" ]] && return 0
  printf '%s' "$manifest" | sha256sum | cut -d' ' -f1
}

mark_done() {
  local step="$1"
  local hash
  hash="$(_step_inputs_hash "$step")"
  {
    echo "timestamp=$(date -Iseconds)"
    echo "inputs_sha256=${hash}"
  } > "${TARGETS_DIR}/${step}.done"
  log_ok "Step '${step}' marked done${hash:+ (inputs ${hash:0:12}...)}"
}

is_done() {
  local step="$1"
  local marker="${TARGETS_DIR}/${step}.done"
  [[ -f "$marker" ]] || return 1

  local expected
  expected="$(_step_inputs_hash "$step")"
  # Existence-only steps (no declared inputs).
  [[ -z "$expected" ]] && return 0

  local stored
  stored="$(grep -E '^inputs_sha256=' "$marker" 2>/dev/null | head -1 | cut -d= -f2)"
  if [[ -z "$stored" ]]; then
    # Legacy marker (pre-upgrade, timestamp only): cannot verify -> accept once.
    log_warn "Step '${step}' marker is legacy (no inputs hash); treating as done. rm '${marker}' to force re-run."
    return 0
  fi
  if [[ "$stored" == "$expected" ]]; then
    return 0
  fi
  log_warn "Step '${step}' inputs changed since completion; will re-run."
  return 1
}

require_done() {
  local step="$1"
  is_done "$step" || die "Prerequisite step '${step}' not completed. Run it first."
}

# ── Jobstore <-> inputs binding (P1-f) ────────────────────────────────────
# Resuming Cactus with --restart against a jobstore that was built from
# DIFFERENT inputs (changed seqfile/tree) silently corrupts the alignment.
# We keep a sidecar file next to the jobstore recording the inputs hash of
# the step that created it, and refuse to --restart on mismatch.
_jobstore_sidecar() { echo "${1}.inputs"; }   # arg: jobstore dir

record_jobstore_inputs() {   # <jobstore_dir> <step>
  _step_inputs_hash "$2" > "$(_jobstore_sidecar "$1")" 2>/dev/null || true
}

# Returns: 0 = inputs match, 1 = MISMATCH, 2 = no record (legacy jobstore).
check_jobstore_inputs() {    # <jobstore_dir> <step>
  local sc cur stored
  sc="$(_jobstore_sidecar "$1")"
  [[ -f "$sc" ]] || return 2
  cur="$(_step_inputs_hash "$2")"
  stored="$(cat "$sc" 2>/dev/null)"
  [[ "$stored" == "$cur" ]]
}

# ── Cactus pre-run validation (preflight.py, P2) ──────────────────────────
# Validates the seqFile (tree parses/rooted, genomes exist, leaf<->genome
# match, softmasking/N stats) BEFORE spending hours of compute. Set
# HOMOPAN_SKIP_PREFLIGHT=1 to bypass.
PREFLIGHT_PY="${PROJECT_ROOT}/.claude/skills/comparative-genomics-cactus/scripts/preflight.py"
run_preflight() {   # <seqfile>
  if [[ "${HOMOPAN_SKIP_PREFLIGHT:-0}" == "1" ]]; then
    log_warn "Preflight skipped (HOMOPAN_SKIP_PREFLIGHT=1)"
    return 0
  fi
  if [[ ! -f "${PREFLIGHT_PY}" ]]; then
    log_warn "preflight.py not found; skipping pre-run validation"
    return 0
  fi
  if ! command -v python3 &>/dev/null; then
    log_warn "python3 not found; skipping preflight"
    return 0
  fi
  log_step "Preflight validation (preflight.py)"
  if python3 "${PREFLIGHT_PY}" --seqfile "$1"; then
    log_ok "Preflight passed"
  else
    die "Preflight failed for $(sanitize_path "$1"). Fix issues before Cactus, or set HOMOPAN_SKIP_PREFLIGHT=1 to override."
  fi
}

# ── Step locking (prevents concurrent execution) ─────────────────────────
acquire_step_lock() {
  local step="$1"
  local lockfile="${TARGETS_DIR}/${step}.lock"
  exec {_STEP_LOCK_FD}>"${lockfile}"
  if ! flock -n "${_STEP_LOCK_FD}"; then
    die "Step '${step}' is already running (locked by another process)"
  fi
  # Lock held until fd closes at script exit
}

# ── Container wrappers ───────────────────────────────────────────────────
# Optionally route the container runtime through the OS sandbox (EXPERIMENTAL).
# HOMOPAN_SANDBOX_COMPUTE=1 runs apptainer under scripts/sandbox_run.sh with the
# data dirs bound and (by default) no network. NOTE: nested apptainer-inside-
# bubblewrap can require host config (nested user namespaces); leave this OFF if
# your apptainer cannot run nested. Default OFF -> behaviour unchanged.
_apptainer() {
  if [[ "${HOMOPAN_SANDBOX_COMPUTE:-0}" == "1" ]]; then
    HOMOPAN_EXTRA_BINDS="${HOMOPAN_EXTRA_BINDS:-} ${GENOMES_DIR} ${TEST_GENOMES_DIR} ${WORK_DIR}" \
    HOMOPAN_PASS_ENV="APPTAINER_CACHEDIR APPTAINER_TMPDIR ${HOMOPAN_PASS_ENV:-}" \
      bash "${SCRIPTS_DIR}/sandbox_run.sh" apptainer "$@"
  else
    apptainer "$@"
  fi
}

run_in_container() {
  [[ -f "${SIF}" ]] || die "Container not found: $(sanitize_path "${SIF}")"
  local bind_args=("--bind" "${PROJECT_ROOT}:${PROJECT_ROOT}")
  # If WORK_DIR is on a different filesystem, bind it too
  if [[ "${WORK_DIR}" != "${PROJECT_ROOT}"* ]]; then
    bind_args+=("--bind" "${WORK_DIR}:${WORK_DIR}")
  fi
  _apptainer exec "${bind_args[@]}" "${SIF}" "$@"
}

run_cactus() {
  [[ -f "${SIF}" ]] || die "Container not found: $(sanitize_path "${SIF}")"
  local bind_args=("--bind" "${PROJECT_ROOT}:${PROJECT_ROOT}")
  if [[ "${WORK_DIR}" != "${PROJECT_ROOT}"* ]]; then
    bind_args+=("--bind" "${WORK_DIR}:${WORK_DIR}")
  fi
  # timeout must wrap a real binary (bash or apptainer), never a shell function.
  if [[ "${HOMOPAN_SANDBOX_COMPUTE:-0}" == "1" ]]; then
    HOMOPAN_EXTRA_BINDS="${HOMOPAN_EXTRA_BINDS:-} ${GENOMES_DIR} ${TEST_GENOMES_DIR} ${WORK_DIR}" \
    HOMOPAN_PASS_ENV="APPTAINER_CACHEDIR APPTAINER_TMPDIR ${HOMOPAN_PASS_ENV:-}" \
      timeout "${CACTUS_TIMEOUT:-172800}" bash "${SCRIPTS_DIR}/sandbox_run.sh" \
        apptainer exec "${bind_args[@]}" "${SIF}" cactus --binariesMode local "$@"
  else
    timeout "${CACTUS_TIMEOUT:-172800}" \
      apptainer exec "${bind_args[@]}" "${SIF}" cactus --binariesMode local "$@"
  fi
}

run_halStats()    { run_in_container halStats "$@"; }
run_halValidate() { run_in_container halValidate "$@"; }
run_hal2fasta()   { run_in_container hal2fasta "$@"; }

# samtools: use host version (1.21, newer than container's 1.11)
run_samtools() { samtools "$@"; }

# ── Disk space check ─────────────────────────────────────────────────────
check_disk() {
  local min_gb="${1:-${DISK_WARN_GB}}"
  local avail_gb
  avail_gb=$(df -BG "${PROJECT_ROOT}" | awk 'NR==2{print $4}' | tr -d 'G')
  if (( avail_gb < min_gb )); then
    log_warn "Only ${avail_gb} GB free (need ${min_gb} GB recommended)"
    return 1
  fi
  log_ok "Disk: ${avail_gb} GB free"
  return 0
}

# ── File size check (non-empty) ──────────────────────────────────────────
assert_file_nonempty() {
  local f="$1"
  local label="${2:-${f}}"
  [[ -f "$f" ]] || die "File not found: $(sanitize_path "$f")"
  [[ -s "$f" ]] || die "File is empty: $(sanitize_path "$f")"
  log_ok "${label}: $(du -h "$f" | cut -f1)"
}

# ── Checksum helper ──────────────────────────────────────────────────────
compute_sha256() {
  sha256sum "$1" | cut -d' ' -f1
}

# ── Environment capture ──────────────────────────────────────────────────
capture_env() {
  local outfile="${1:-${QC_DIR}/environment.txt}"
  {
    echo "=== Environment captured at $(_ts) ==="
    echo "PROJECT_ROOT=${PROJECT_ROOT}"
    echo "SIF=$(sanitize_path "${SIF}")"
    echo "hostname=$(hostname)"
    echo "uname=$(uname -a)"
    echo "cores=$(nproc)"
    echo "ram_gb=$(free -g | awk '/Mem:/{print $2}')"
    echo "disk_avail_gb=$(df -BG "${PROJECT_ROOT}" | awk 'NR==2{print $4}' | tr -d 'G')"
    echo "apptainer=$(apptainer --version 2>/dev/null || echo 'N/A')"
    echo "samtools=$(samtools --version 2>/dev/null | head -1 || echo 'N/A')"
    echo "bedtools=$(bedtools --version 2>/dev/null || echo 'N/A')"
    echo "cactus_in_container=$(run_in_container cactus --version 2>&1 | head -1 || echo 'N/A')"
    echo "halStats_in_container=$(run_in_container halStats --version 2>&1 | head -1 || echo 'N/A')"
    echo "jq=$(jq --version 2>/dev/null || echo 'N/A')"
    echo "bash=${BASH_VERSION}"
  } > "$outfile"
  log_ok "Environment captured to $(sanitize_path "$outfile")"
}

# ── Script banner ─────────────────────────────────────────────────────────
script_banner() {
  local name="$1"
  echo ""
  echo -e "${BOLD}========================================${NC}"
  echo -e "${BOLD}  ${name}${NC}"
  echo -e "${BOLD}  $(date)${NC}"
  echo -e "${BOLD}========================================${NC}"
  echo ""
}

# ── Ensure dirs exist on source ──────────────────────────────────────────
ensure_dirs
