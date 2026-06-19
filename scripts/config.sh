#!/usr/bin/env bash
# config.sh -- Shared library for HomoPan Ancestor pipeline
# Source this from every script: source "$(dirname "$0")/config.sh"
# Provides: PROJECT_ROOT, SIF, wrappers, logging, signals, idempotency
set -euo pipefail

# ── Project root (derived from BASH_SOURCE, never hardcoded) ──────────────
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"

# ── Canonical jq: route bare `jq` to a capable build WITHOUT polluting PATH ─
# /snap/bin/jq -> /usr/bin/snap is confined (no file-path reads) + snapd-bound.
# We must NOT prepend a conda BIN dir to PATH -- that would also shadow samtools
# /bedtools with conda versions and break the toolchain lock (a real determinant
# of FASTA bytes). Instead resolve a capable jq and define a `jq` shell function
# so ONLY jq is redirected. Override with HOMOPAN_JQ.
for _jqc in "${HOMOPAN_JQ:-}" \
            "${HOME}/miniconda3/envs/homopan_ancestor/bin/jq" \
            "${HOME}/miniconda3/bin/jq" \
            "${HOME}/anaconda3/envs/homopan_ancestor/bin/jq" \
            /usr/bin/jq /bin/jq; do
  if [[ -n "${_jqc}" && -x "${_jqc}" ]]; then export HOMOPAN_JQ="${_jqc}"; break; fi
done
unset _jqc
if [[ -n "${HOMOPAN_JQ:-}" ]]; then jq() { "${HOMOPAN_JQ}" "$@"; }; fi

# ── Run identity (one id shared by every step of a single pipeline run) ────
# The orchestrator sets+exports it first; child step scripts inherit it.
RUN_ID="${HOMOPAN_RUN_ID:-$(date +%Y%m%d_%H%M%S)_$$}"
export HOMOPAN_RUN_ID="${RUN_ID}"

# ── State namespace (per-agent / per-experiment isolation) ────────────────
# HOMOPAN_RUN_NS isolates ALL mutable pipeline state under runs/<NS>/ so that
# multiple cooperative agents can run simultaneously on the same repo without
# colliding on targets/, results/, work/, logs/, seqfiles or markers.
#   unset/empty -> STATE_ROOT = PROJECT_ROOT      (legacy layout; nothing moves)
#   set         -> STATE_ROOT = PROJECT_ROOT/runs/<NS>
# genomes/ (inputs) and the SIF are NEVER namespaced: shared, read-only.
RUN_NS="${HOMOPAN_RUN_NS:-}"
if [[ -n "${RUN_NS}" ]]; then
  STATE_ROOT="${PROJECT_ROOT}/runs/${RUN_NS}"
else
  STATE_ROOT="${PROJECT_ROOT}"
fi

# ── Core paths ────────────────────────────────────────────────────────────
GENOMES_DIR="${PROJECT_ROOT}/genomes"          # shared, read-only input (NOT namespaced)
TEST_GENOMES_DIR="${STATE_ROOT}/test_genomes"
RESULTS_DIR="${STATE_ROOT}/results"
RESULTS_TEST="${RESULTS_DIR}/test"
RESULTS_FULL="${RESULTS_DIR}/full"
RESULTS_ANCESTORS="${RESULTS_DIR}/ancestors"
RESULTS_REGIONS="${RESULTS_DIR}/regions"
RESULTS_REPORTS="${RESULTS_DIR}/reports"
LOGS_DIR="${STATE_ROOT}/logs"
QC_DIR="${STATE_ROOT}/qc"
TARGETS_DIR="${STATE_ROOT}/targets"

# ── Container ─────────────────────────────────────────────────────────────
SIF="${PROJECT_ROOT}/cactus_v3.0.1.sif"        # shared, read-only (NOT namespaced)
export APPTAINER_CACHEDIR="${PROJECT_ROOT}/apptainer_cache"   # shared image cache
export APPTAINER_TMPDIR="${STATE_ROOT}/apptainer_tmp"         # per-NS (extraction collides otherwise)

# ── Biology ───────────────────────────────────────────────────────────────
SPECIES=(homo_sapiens pan_paniscus pan_troglodytes gorilla_gorilla_gorilla pongo_abelii)
ANCESTOR_NODES=(Anc_HomoPan Pan Homininae Root)
# Branch lengths from TimeTree (million years, scaled to substitutions/site approx)
# homo-pan split ~6.7 Mya, pan-pan split ~2.0 Mya, gorilla split ~9.1 Mya, pongo split ~15.2 Mya
NEWICK_TREE='(((homo_sapiens:0.0067,(pan_paniscus:0.002,pan_troglodytes:0.002)Pan:0.0047)Anc_HomoPan:0.0024,gorilla_gorilla_gorilla:0.0091)Homininae:0.0061,pongo_abelii:0.0152)Root;'

# ── Seqfile paths ─────────────────────────────────────────────────────────
SEQFILE_FULL="${STATE_ROOT}/primates.seqfile"
SEQFILE_TEST="${STATE_ROOT}/primates.test.seqfile"

# ── Result file paths ─────────────────────────────────────────────────────
HAL_TEST="${RESULTS_TEST}/primates.test.hal"
HAL_FULL="${RESULTS_FULL}/primates.full.hal"

# ── Alternate work directory (for disk overflow) ─────────────────────────
# Set HOMOPAN_WORKDIR env var to use an alternate disk (e.g. /mnt/s1)
# Example: HOMOPAN_WORKDIR=/mnt/s1/homopan_work bash scripts/run_all_full.sh
# When an overflow disk is given, still isolate per-NS so concurrent agents
# don't share a jobstore; otherwise default under the (possibly namespaced)
# STATE_ROOT. Unset NS + unset HOMOPAN_WORKDIR => PROJECT_ROOT/work (legacy).
if [[ -n "${HOMOPAN_WORKDIR:-}" ]]; then
  WORK_DIR="${HOMOPAN_WORKDIR}${RUN_NS:+/${RUN_NS}}"
else
  WORK_DIR="${STATE_ROOT}/work"
fi
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
# Every line carries the run id (and agent/session when the env provides them)
# so interleaved output from concurrent or resumed runs is attributable (#10).
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_AGENT_TAG="${HOMOPAN_AGENT:-${CLAUDE_AGENT:-}}"
_SESSION_TAG="${HOMOPAN_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
_logtag() {
  printf '%s' "${RUN_ID}"
  [[ -n "${_AGENT_TAG}" ]]   && printf '/%s' "${_AGENT_TAG}"
  [[ -n "${_SESSION_TAG}" ]] && printf '/%s' "${_SESSION_TAG}"
}

# Logs go to STDERR, never stdout: several helpers (run_in_container, the
# sandbox/seed probes) run inside command substitution or `cmd > file`, so a
# log line on stdout would contaminate the captured data (e.g. a hal2fasta
# FASTA or a halStats value). stderr is still captured by the steps' `2>&1|tee`.
log_info()  { echo -e "${BLUE}[$(_ts)]${NC}[$(_logtag)] ${BOLD}INFO${NC}  $*" >&2; }
log_ok()    { echo -e "${GREEN}[$(_ts)]${NC}[$(_logtag)] ${GREEN}OK${NC}    $*" >&2; }
log_warn()  { echo -e "${YELLOW}[$(_ts)]${NC}[$(_logtag)] ${YELLOW}WARN${NC}  $*" >&2; }
log_error() { echo -e "${RED}[$(_ts)]${NC}[$(_logtag)] ${RED}ERROR${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[$(_ts)]${NC}[$(_logtag)] ${BOLD}STEP${NC}  $*" >&2; }

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
    "${TEST_GENOMES_DIR}" "${WORK_DIR}"
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
#   - large files (genomes, HAL): size + mtime + sampled content hash of the
#     first & last 1 MiB (fast; more robust than size:mtime alone)

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
    # Large file: size + mtime + sampled content (first & last 1 MiB). Reads
    # ~2 MiB instead of GBs, yet catches content edits in the sampled regions
    # that size:mtime alone would miss.
    local sample
    sample=$( { head -c 1048576 "$f"; tail -c 1048576 "$f"; } 2>/dev/null | sha256sum | cut -d' ' -f1)
    printf '%s:%s:%s:%s\n' "$f" "$sz" "$(file_mtime_epoch "$f")" "${sample}"
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

# Declared OUTPUTS per step: the artifact files a step produces. Tracking these
# lets is_done detect a corrupted/truncated/deleted output AFTER it was marked
# done and force a re-run -- the input hash alone cannot catch that. Empty list
# => no output verification (e.g. validation-only or environment steps).
step_outputs() {
  local step="$1"
  case "$step" in
    02_make_test_fastas)
      printf '%s\n' "${TEST_GENOMES_DIR}"/*.fa ;;
    03_make_seqfiles)
      printf '%s\n' "${SEQFILE_TEST}" "${SEQFILE_FULL}" ;;
    04_run_test_cactus)
      printf '%s\n' "${HAL_TEST}" ;;
    05_validate_test_hal)
      printf '%s\n' "${RESULTS_ANCESTORS}/Anc_HomoPan.test.fa" ;;
    06_run_full_cactus)
      printf '%s\n' "${HAL_FULL}" ;;
    08_extract_ancestors)
      local anc
      for anc in "${ANCESTOR_NODES[@]}"; do
        printf '%s\n' "${RESULTS_ANCESTORS}/${anc}.fa"
      done ;;
    09_make_report)
      printf '%s\n' "${RESULTS_REPORTS}/HomoPan_ancestor_report.md" ;;
    *)
      : ;;  # no declared outputs -> no output verification
  esac
}

# Hash a step's output manifest. Echoes empty string when no outputs declared.
# A MISSING declared output makes the hash differ from the recorded one, so
# is_done re-runs the step. Uses the same size/sample fingerprint as inputs, so
# a truncated large HAL (size change) is detected cheaply.
_step_outputs_hash() {
  local step="$1" item manifest=""
  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    manifest+="$(_input_fingerprint "$item")"$'\n'
  done < <(step_outputs "$step")
  [[ -z "$manifest" ]] && return 0
  printf '%s' "$manifest" | sha256sum | cut -d' ' -f1
}

# Marker schema version. Bump when the marker format changes so that markers
# written by an older layout are treated as invalid (re-run) rather than
# silently misread.
_MARKER_SCHEMA=2

# A marker line tells whether the step DECLARES inputs/outputs. We must
# distinguish "declared, hashed to empty" from "not declared at all"; the empty
# string is ambiguous, so we write the literal token "none" when a step has no
# declared inputs/outputs and store the hash otherwise.
_hash_or_none() { [[ -z "$1" ]] && printf 'none' || printf '%s' "$1"; }

mark_done() {
  local step="$1"
  local ihash ohash marker tmp
  ihash="$(_step_inputs_hash "$step")"
  ohash="$(_step_outputs_hash "$step")"
  marker="${TARGETS_DIR}/${step}.done"
  # Atomic write: render to a temp file on the SAME filesystem, then rename.
  # A crash mid-write leaves only the .tmp (ignored by is_done), never a
  # half-written marker that would skip the step forever.
  tmp="$(mktemp "${marker}.XXXXXX.tmp")"
  {
    echo "schema=${_MARKER_SCHEMA}"
    echo "timestamp=$(date -Iseconds)"
    echo "run_id=${RUN_ID}"
    echo "inputs_sha256=$(_hash_or_none "${ihash}")"
    echo "outputs_sha256=$(_hash_or_none "${ohash}")"
  } > "${tmp}"
  # fsync the file and rename so the rename cannot land before the data.
  sync "${tmp}" 2>/dev/null || true
  mv -f "${tmp}" "${marker}"
  log_ok "Step '${step}' marked done${ihash:+ (inputs ${ihash:0:12}...)}"
}

is_done() {
  local step="$1"
  local marker="${TARGETS_DIR}/${step}.done"
  [[ -f "$marker" ]] || return 1

  # Reject markers from an older/unknown schema -> re-run rather than misread.
  local schema
  schema="$(grep -E '^schema=' "$marker" 2>/dev/null | head -1 | cut -d= -f2)"
  if [[ "${schema}" != "${_MARKER_SCHEMA}" ]]; then
    log_warn "Step '${step}' marker has schema '${schema:-<none>}' (expected ${_MARKER_SCHEMA}); treating as not done. Will re-run."
    return 1
  fi

  # ── Verify inputs ───────────────────────────────────────────────────────
  local expected_i stored_i
  expected_i="$(_step_inputs_hash "$step")"
  [[ -z "$expected_i" ]] && expected_i="none"
  stored_i="$(grep -E '^inputs_sha256=' "$marker" 2>/dev/null | head -1 | cut -d= -f2)"
  if [[ -z "$stored_i" ]]; then
    # No inputs hash recorded: cannot trust the marker. Re-run (fail-closed),
    # NOT accept-as-legacy -- a crash-truncated marker must never skip a step.
    log_warn "Step '${step}' marker is missing its inputs hash (corrupt/legacy); treating as not done. Will re-run."
    return 1
  fi
  if [[ "$stored_i" != "$expected_i" ]]; then
    log_warn "Step '${step}' inputs changed since completion; will re-run."
    return 1
  fi

  # ── Verify outputs still exist and match ────────────────────────────────
  local expected_o stored_o
  expected_o="$(_step_outputs_hash "$step")"
  [[ -z "$expected_o" ]] && expected_o="none"
  stored_o="$(grep -E '^outputs_sha256=' "$marker" 2>/dev/null | head -1 | cut -d= -f2)"
  if [[ -z "$stored_o" ]]; then
    log_warn "Step '${step}' marker is missing its outputs hash (corrupt/legacy); treating as not done. Will re-run."
    return 1
  fi
  if [[ "$stored_o" != "$expected_o" ]]; then
    log_warn "Step '${step}' output artifact is missing or changed since completion (corruption/truncation/deletion); will re-run."
    return 1
  fi

  return 0
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

# ── Orchestrator step runner with bounded retry ──────────────────────────
# A transient fault (network blip while pulling refs, brief OOM, flaky FS)
# should not throw away hours of completed pipeline work. We retry a failed
# step up to HOMOPAN_STEP_RETRIES times (default 2) with a fixed backoff.
# This composes with Toil's own per-job --retryCount and with Cactus
# --restart: a retried Cactus step resumes from its preserved jobstore instead
# of starting over. Set HOMOPAN_STEP_RETRIES=0 to disable.
run_step_with_retry() {
  local step="$1" script="$2"
  local max_retries="${HOMOPAN_STEP_RETRIES:-2}"
  local delay="${HOMOPAN_STEP_RETRY_DELAY:-15}"
  local attempt=1 rc=0
  while :; do
    log_step "Running ${step} (attempt ${attempt}/$((max_retries + 1)))"
    rc=0; bash "${script}" || rc=$?
    (( rc == 0 )) && return 0
    if (( attempt > max_retries )); then
      log_error "Step ${step} FAILED after ${attempt} attempt(s) (exit ${rc})"
      return "${rc}"
    fi
    log_warn "Step ${step} failed (exit ${rc}); retrying in ${delay}s (transient-fault recovery)..."
    sleep "${delay}"
    ((attempt++)) || true
  done
}

# ── Sandbox-by-default for compute (#6: opt-out, probe + fallback) ────────
# Policy: the compute SHOULD run through the OS sandbox (scripts/sandbox_run.sh)
# by default. But nested apptainer-in-bubblewrap needs unprivileged user
# namespaces, which not every host has -- so we PROBE once and, if the sandbox
# cannot run here, warn loudly and FALL BACK to direct compute (so the pipeline
# still works) rather than silently doing nothing.
#
# Override the probe explicitly:
#   HOMOPAN_SANDBOX_COMPUTE=1  force sandboxed compute (fail if it can't run)
#   HOMOPAN_SANDBOX_COMPUTE=0  force direct compute (no sandbox)
#   (unset / "auto")          default: probe, sandbox if possible else fall back
_sandbox_probe_cache=""
_probe_sandbox_ok() {
  local bw="${HOMOPAN_BWRAP_BIN:-bwrap}"
  if ! command -v "${bw}" >/dev/null 2>&1; then
    log_warn "sandbox-compute probe: '${bw}' not found."
    return 1
  fi
  # Can bwrap actually create the namespaces here? (unprivileged userns check)
  if ! "${bw}" --unshare-user --unshare-net --ro-bind /usr /usr --tmpfs /tmp true >/dev/null 2>&1; then
    log_warn "sandbox-compute probe: bwrap cannot create a user namespace on this host (needs unprivileged userns)."
    return 1
  fi
  return 0
}
# Record the EFFECTIVE sandbox decision for this run so the manifest can report
# it regardless of which step writes the manifest (the pipeline spans processes,
# but they share the namespaced QC_DIR). Best-effort; never fails a run.
SANDBOX_EFFECTIVE="unknown"
_record_sandbox() {                 # <true|false>
  SANDBOX_EFFECTIVE="$1"
  [[ -n "${QC_DIR:-}" ]] || return 0
  mkdir -p "${QC_DIR}" 2>/dev/null || return 0
  printf '%s\n' "$1" > "${QC_DIR}/.sandbox_effective" 2>/dev/null || true
}
# Returns 0 if compute should be sandboxed, 1 otherwise. Probes once, caches.
# FAIL-CLOSED (P0.2): if a sandbox is requested (default/auto or forced) but the
# host cannot provide one, ABORT rather than silently running unisolated. The
# only ways to run WITHOUT isolation are explicit and recorded (sandboxed:false):
#   HOMOPAN_SANDBOX_COMPUTE=0       opt out of sandboxing entirely
#   HOMOPAN_ALLOW_UNSANDBOXED=1     auto-mode: run direct when probe fails
sandbox_compute_active() {
  case "${HOMOPAN_SANDBOX_COMPUTE:-auto}" in
    1)
      if _probe_sandbox_ok; then _record_sandbox true; return 0; fi
      die "sandbox-compute forced (HOMOPAN_SANDBOX_COMPUTE=1) but this host cannot create a sandbox. Fix unprivileged userns/bwrap, or set HOMOPAN_SANDBOX_COMPUTE=0 to opt out explicitly."
      ;;
    0) _record_sandbox false; return 1 ;;
  esac
  # auto (default): fail-closed unless explicitly allowed to run unsandboxed.
  if [[ -z "${_sandbox_probe_cache}" ]]; then
    if _probe_sandbox_ok; then
      _sandbox_probe_cache=1
      log_info "sandbox-compute: enabled by default (probe OK). Disable with HOMOPAN_SANDBOX_COMPUTE=0."
    elif [[ "${HOMOPAN_ALLOW_UNSANDBOXED:-0}" == "1" ]]; then
      _sandbox_probe_cache=0
      log_warn "############################################################"
      log_warn "# SANDBOX DISABLED: compute will run WITHOUT isolation.     #"
      log_warn "# (HOMOPAN_ALLOW_UNSANDBOXED=1) -> manifest sandboxed:false #"
      log_warn "# This is NOT a contained run.                              #"
      log_warn "############################################################"
    else
      die "sandbox-compute: cannot create a sandbox on this host (unprivileged userns/bwrap unavailable) and fail-closed is the default. Choose ONE: (a) fix userns/bwrap; (b) HOMOPAN_ALLOW_UNSANDBOXED=1 to run unsandboxed explicitly (recorded sandboxed:false); (c) HOMOPAN_SANDBOX_COMPUTE=0 to opt out."
    fi
  fi
  if [[ "${_sandbox_probe_cache}" == "1" ]]; then _record_sandbox true; return 0; fi
  _record_sandbox false; return 1
}

# ── Cactus reproducibility seed (#10) ─────────────────────────────────────
# A fixed seed makes the alignment reproducible. cactus only accepts --seed on
# versions that support it, so probe `cactus --help` ONCE (cheap vs hours of
# alignment) and pass it only when supported; otherwise warn and continue.
# Set CACTUS_SEED to a specific integer, or CACTUS_SEED="" to disable seeding.
_cactus_seed_cache=""
_cactus_seed_args() {
  local seed="${CACTUS_SEED-0}"
  [[ -z "${seed}" ]] && return 0   # seeding explicitly disabled
  if [[ -z "${_cactus_seed_cache}" ]]; then
    if run_in_container cactus --help 2>&1 | grep -q -- '--seed'; then
      _cactus_seed_cache="yes"
    else
      _cactus_seed_cache="no"
      log_warn "Cactus in this container does not support --seed; runs will not be seed-reproducible."
    fi
  fi
  [[ "${_cactus_seed_cache}" == "yes" ]] && printf '%s\n' "--seed" "${seed}"
}

# ── Container wrappers ───────────────────────────────────────────────────
# Routes the container runtime through the OS sandbox when sandbox_compute_active
# (see #6 above): sandbox_run.sh binds the data dirs and (by default) cuts
# network. Falls back to direct apptainer when the host can't nest the sandbox.
_apptainer() {
  if sandbox_compute_active; then
    HOMOPAN_EXTRA_BINDS="${HOMOPAN_EXTRA_BINDS:-} $(realpath -m "${GENOMES_DIR}" 2>/dev/null) $(realpath -m "${TEST_GENOMES_DIR}" 2>/dev/null) $(realpath -m "${WORK_DIR}" 2>/dev/null)" \
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
  local iso_args=()
  [[ "${HOMOPAN_APPTAINER_ISOLATE:-0}" == "1" ]] && iso_args+=(--containall --no-home --cleanenv)
  [[ "${HOMOPAN_APPTAINER_NONET:-0}" == "1" ]]   && iso_args+=(--net --network none)
  _apptainer exec "${iso_args[@]}" "${bind_args[@]}" "${SIF}" "$@"
}

run_cactus() {
  [[ -f "${SIF}" ]] || die "Container not found: $(sanitize_path "${SIF}")"
  local bind_args=("--bind" "${PROJECT_ROOT}:${PROJECT_ROOT}")
  if [[ "${WORK_DIR}" != "${PROJECT_ROOT}"* ]]; then
    bind_args+=("--bind" "${WORK_DIR}:${WORK_DIR}")
  fi
  local iso_args=()
  [[ "${HOMOPAN_APPTAINER_ISOLATE:-0}" == "1" ]] && iso_args+=(--containall --no-home --cleanenv)
  [[ "${HOMOPAN_APPTAINER_NONET:-0}" == "1" ]]   && iso_args+=(--net --network none)
  # Toil retries each failed job up to --retryCount times before aborting the
  # whole run -- absorbs transient faults (network blips, OOM-kill, flaky FS)
  # without losing hours of completed work. Override with CACTUS_RETRY_COUNT.
  local retry_args=(--retryCount "${CACTUS_RETRY_COUNT:-2}")
  # Reproducibility seed (no-op if the container's cactus lacks --seed).
  local seed_args=(); mapfile -t seed_args < <(_cactus_seed_args)
  # Extra cactus flags (determinism experiment): e.g. force single-threaded
  # consolidation/lastz, the suspected non-determinism driver:
  #   CACTUS_EXTRA_ARGS="--consCores 1 --lastzCores 1 --maxCores 1"
  local extra_args=(); [[ -n "${CACTUS_EXTRA_ARGS:-}" ]] && read -r -a extra_args <<<"${CACTUS_EXTRA_ARGS}"
  # timeout must wrap a real binary (bash or apptainer), never a shell function.
  if sandbox_compute_active; then
    HOMOPAN_EXTRA_BINDS="${HOMOPAN_EXTRA_BINDS:-} $(realpath -m "${GENOMES_DIR}" 2>/dev/null) $(realpath -m "${TEST_GENOMES_DIR}" 2>/dev/null) $(realpath -m "${WORK_DIR}" 2>/dev/null)" \
    HOMOPAN_PASS_ENV="APPTAINER_CACHEDIR APPTAINER_TMPDIR ${HOMOPAN_PASS_ENV:-}" \
      timeout "${CACTUS_TIMEOUT:-172800}" bash "${SCRIPTS_DIR}/sandbox_run.sh" \
        apptainer exec "${iso_args[@]}" "${bind_args[@]}" "${SIF}" cactus --binariesMode local "${retry_args[@]}" "${seed_args[@]}" "${extra_args[@]}" "$@"
  else
    timeout "${CACTUS_TIMEOUT:-172800}" \
      apptainer exec "${iso_args[@]}" "${bind_args[@]}" "${SIF}" cactus --binariesMode local "${retry_args[@]}" "${seed_args[@]}" "${extra_args[@]}" "$@"
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

# ── HAL structural validation (gate before mark_done) ─────────────────────
# Non-empty is NOT enough: a truncated-but-non-empty HAL passes -s but is
# corrupt. halValidate parses the container structure end-to-end, so a partial
# write fails it. Call this as the completion gate in the Cactus steps, BEFORE
# mark_done, so a corrupt alignment is never recorded as done.
assert_hal_valid() {
  local hal="$1"
  local label="${2:-$(basename "$hal")}"
  assert_file_nonempty "$hal" "$label"
  local out="${QC_DIR}/$(basename "$hal").validate.txt"
  log_step "halValidate gate: ${label}"
  if run_halValidate "$hal" > "${out}" 2>&1; then
    grep -q "File valid" "${out}" || log_warn "halValidate exited 0 but did not print 'File valid'"
    log_ok "halValidate: ${label} is structurally valid"
  else
    local rc=$?
    log_error "halValidate failed for ${label} (exit ${rc}):"
    cat "${out}"
    die "HAL is invalid/corrupt: $(sanitize_path "$hal"). Refusing to mark step done."
  fi
}

# ── Checksum helper ──────────────────────────────────────────────────────
compute_sha256() {
  sha256sum "$1" | cut -d' ' -f1
}

# ── Clean in-container cactus version (X.Y.Z) ──────────────────────────────
# run_in_container's first call may emit a sandbox-probe WARN on stderr; merge
# then extract only the version triple so provenance/lock never capture noise.
cactus_version() {
  run_in_container cactus --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# ── Ancestral FASTA quality gate (#4: stop the report from "lying") ────────
# A reconstructed ancestor that is mostly N is a DEGENERATE result, not a
# success -- but assert_file_nonempty passes it happily. Compute the no-call
# fraction (N/n, incl. soft-masked no-calls) in one pass.
fasta_n_fraction() {   # <fasta> -> prints fraction 0..1
  awk '!/^>/{ s=$0; n=gsub(/[Nn]/,"",s); N+=n; T+=length($0) }
       END{ if(T==0){print "1.0000"} else {printf "%.4f", N/T} }' "$1"
}

# Records + gates the N-fraction. Loud WARN above HOMOPAN_WARN_N_FRAC (0.50),
# fail-closed above HOMOPAN_MAX_N_FRAC (0.90) so a garbage ancestor is never
# marked done as a success. Echoes the fraction on stdout (logs go to stderr).
assert_ancestor_quality() {   # <fasta> <label>
  local fa="$1" label="${2:-$(basename "$1")}"
  local warn="${HOMOPAN_WARN_N_FRAC:-0.50}" max="${HOMOPAN_MAX_N_FRAC:-0.90}"
  local nf; nf="$(fasta_n_fraction "$fa")"
  if awk "BEGIN{exit !(${nf} > ${max})}"; then
    die "Ancestor '${label}' is ${nf} N (> ${max}): degenerate reconstruction; refusing to mark done. Override with HOMOPAN_MAX_N_FRAC=1 if intentional."
  elif awk "BEGIN{exit !(${nf} > ${warn})}"; then
    log_warn "Ancestor '${label}' is ${nf} N (> ${warn}): LOW-CONFIDENCE reconstruction (recorded in report)."
  else
    log_ok "Ancestor '${label}' N-fraction ${nf} (OK)"
  fi
  printf '%s' "${nf}"
}

# ── Environment capture ──────────────────────────────────────────────────
capture_env() {
  local outfile="${1:-${QC_DIR}/environment.txt}"
  # Compute the SIF content digest (#10): provenance of the exact container used.
  # apptainer can report it cheaply; fall back to a sha256 of the .sif file.
  local sif_digest="N/A"
  if [[ -f "${SIF}" ]]; then
    sif_digest=$(apptainer sif header "${SIF}" 2>/dev/null | awk -F: '/[Ss]ha256|[Dd]igest/{gsub(/ /,"",$2);print $2;exit}')
    [[ -z "${sif_digest}" || "${sif_digest}" == "N/A" ]] && sif_digest=$(sha256sum "${SIF}" 2>/dev/null | cut -d' ' -f1)
  fi
  # APPEND a timestamped block instead of overwriting (#14): keep run history so
  # an earlier run's environment isn't silently lost when a later step re-runs.
  {
    echo "=== Environment captured at $(_ts) (run ${RUN_ID}) ==="
    echo "run_id=${RUN_ID}"
    echo "agent=${HOMOPAN_AGENT:-${CLAUDE_AGENT:-unknown}}"
    echo "session=${HOMOPAN_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"
    echo "PROJECT_ROOT=${PROJECT_ROOT}"
    echo "SIF=$(sanitize_path "${SIF}")"
    echo "sif_sha256=${sif_digest}"
    echo "hostname=$(hostname)"
    echo "uname=$(uname -a)"
    echo "cores=$(nproc)"
    echo "ram_gb=$(free -g | awk '/Mem:/{print $2}')"
    echo "disk_avail_gb=$(df -BG "${PROJECT_ROOT}" | awk 'NR==2{print $4}' | tr -d 'G')"
    echo "sandbox_compute=${HOMOPAN_SANDBOX_COMPUTE:-auto}"
    echo "cactus_seed=${CACTUS_SEED-0}"
    echo "apptainer=$(apptainer --version 2>/dev/null || echo 'N/A')"
    echo "samtools=$(samtools --version 2>/dev/null | head -1 || echo 'N/A')"
    echo "bedtools=$(bedtools --version 2>/dev/null || echo 'N/A')"
    echo "cactus_in_container=$(run_in_container cactus --version 2>&1 | head -1 || echo 'N/A')"
    echo "halStats_in_container=$(run_in_container halStats --version 2>&1 | head -1 || echo 'N/A')"
    echo "jq=$(jq --version 2>/dev/null || echo 'N/A')"
    echo "bash=${BASH_VERSION}"
    echo ""
  } >> "$outfile"
  log_ok "Environment appended to $(sanitize_path "$outfile") (SIF ${sif_digest:0:12}...)"
}

# ── Toolchain lock verification (reproducibility) ──────────────────────────
# Fail-closed on drift of OUTPUT-DETERMINING tools (strict_* in
# repro/toolchain.lock: SIF digest, in-container cactus, samtools, apptainer);
# WARN only on the rest (audit_*: bedtools/jq/bash/kernel -- not output-
# determining for a containerized run). Override strict failure with
# HOMOPAN_IGNORE_TOOLCHAIN_LOCK=1. Returns 1 on un-overridden strict drift.
verify_toolchain_lock() {
  local lock="${HOMOPAN_TOOLCHAIN_LOCK:-${PROJECT_ROOT}/repro/toolchain.lock}"
  if [[ ! -f "${lock}" ]]; then
    log_warn "toolchain.lock missing; skipping (regenerate: bash scripts/repro_verify.sh --write-lock)"
    return 0
  fi
  declare -A OBS=(
    [sif_sha256]="$(sha256sum "$(realpath -m "${SIF}" 2>/dev/null)" 2>/dev/null | cut -d' ' -f1)"
    [cactus]="$(cactus_version)"
    [samtools]="$(samtools --version 2>/dev/null | head -1)"
    [apptainer]="$(apptainer --version 2>/dev/null)"
    [bedtools]="$(bedtools --version 2>/dev/null)"
    [jq]="$(jq --version 2>/dev/null)"
    [bash]="${BASH_VERSION}"
    [kernel]="$(uname -r)"
  )
  local key val tier name obs strict_fail=0
  while IFS='=' read -r key val; do
    [[ -z "${key}" || "${key}" == \#* || "${key}" == schema ]] && continue
    tier="${key%%_*}"; name="${key#*_}"
    obs="${OBS[${name}]:-<unknown>}"
    if [[ "${obs}" != "${val}" ]]; then
      if [[ "${tier}" == strict ]]; then
        log_error "toolchain drift [${name}]: locked='${val}' observed='${obs}'"; strict_fail=1
      else
        log_warn "toolchain drift (audit) [${name}]: locked='${val}' observed='${obs}'"
      fi
    fi
  done < "${lock}"
  if (( strict_fail )); then
    if [[ "${HOMOPAN_IGNORE_TOOLCHAIN_LOCK:-0}" == "1" ]]; then
      log_warn "Toolchain strict drift OVERRIDDEN (HOMOPAN_IGNORE_TOOLCHAIN_LOCK=1)"
      return 0
    fi
    log_error "Toolchain lock mismatch on output-determining tools. Override with HOMOPAN_IGNORE_TOOLCHAIN_LOCK=1, or regenerate: bash scripts/repro_verify.sh --write-lock"
    return 1
  fi
  log_ok "Toolchain lock verified (strict tier matches)"
  return 0
}

# ── Per-run manifest (#5 longitudinal rigor, #1 reproducibility) ───────────
# One IMMUTABLE JSON per run_id under qc/manifests/ -- never overwritten, so a
# past run survives later runs and scripts/compare_runs.sh can diff two runs
# rigorously: tool versions, SIF digest, seed, params, and input/output hashes.
write_run_manifest() {
  local dir="${QC_DIR}/manifests"; mkdir -p "${dir}"
  local out="${dir}/${RUN_ID}.json"
  # Provenance is BEST-EFFORT: a capture hiccup (SIGPIPE from `| head`, a jq
  # quirk, a confined jq) must NEVER fail an otherwise-successful run. Compute
  # everything in a set+e subshell and always return 0; the caller's `set -e`
  # is thus never tripped by manifest writing.
  # Schema 2 splits the manifest into:
  #   repro{}  -- DETERMINISTIC + VERIFIABLE: every byte-determining input/output
  #               (sorted keys, NO timestamp/host/llm). repro_sha256 hashes it,
  #               so two equivalent runs share an identical repro_sha256 and
  #               differ ONLY in meta{}.
  #   meta{}   -- AUDITABLE-ONLY: timestamp, host, and LLM provenance (session/
  #               agent/effort/model_id). LLM reasoning is non-deterministic and
  #               NOT repo-controllable -- recorded, never promised reproducible.
  (
    set +e
    # determinant captures (repro)
    sif_digest=$(sha256sum "$(realpath -m "${SIF}" 2>/dev/null)" 2>/dev/null | cut -d' ' -f1)
    samtools_v=$(samtools --version 2>/dev/null | head -1)
    cactus_v=$(cactus_version)
    lock_sha=""; [[ -f "${PROJECT_ROOT}/repro/toolchain.lock" ]] && lock_sha=$(compute_sha256 "${PROJECT_ROOT}/repro/toolchain.lock")
    seed_active=false; [[ -n "$(_cactus_seed_args 2>/dev/null)" ]] && seed_active=true
    # Hash the seqFile over PATH-NORMALIZED content: the file embeds namespaced
    # absolute paths (runs/<NS>/...), so a raw sha would be namespace-dependent
    # and break repro-equality for the SAME experiment. Strip the STATE_ROOT/
    # PROJECT_ROOT prefixes so the hash captures the logical content (which
    # genomes + tree) only -> namespace-invariant.
    _normseq() { sed "s#${STATE_ROOT}/##g; s#${PROJECT_ROOT}/##g" "$1" 2>/dev/null | sha256sum | cut -d' ' -f1; }
    seqf_test=""; [[ -f "${SEQFILE_TEST}" ]] && seqf_test=$(_normseq "${SEQFILE_TEST}")
    seqf_full=""; [[ -f "${SEQFILE_FULL}" ]] && seqf_full=$(_normseq "${SEQFILE_FULL}")
    hal_full=""; [[ -f "${HAL_FULL}" ]] && hal_full=$(compute_sha256 "${HAL_FULL}")
    hal_test=""; [[ -f "${HAL_TEST}" ]] && hal_test=$(compute_sha256 "${HAL_TEST}")
    # auditable captures (meta)
    apptainer_v=$(apptainer --version 2>/dev/null)
    sandboxed_eff=$(cat "${QC_DIR}/.sandbox_effective" 2>/dev/null || echo unknown)
    llm_session="${CLAUDE_CODE_SESSION_ID:-${HOMOPAN_SESSION_ID:-unknown}}"
    llm_agent="${AI_AGENT:-${HOMOPAN_AGENT:-${CLAUDE_AGENT:-unknown}}}"
    llm_effort="${CLAUDE_EFFORT:-unknown}"
    llm_model="${HOMOPAN_MODEL_ID:-unexposed}"   # exact model id is NOT exposed to the shell

    JQ=""
    if command -v jq &>/dev/null; then JQ=jq; else
      for c in "${HOME}/miniconda3/envs/homopan_ancestor/bin/jq" /usr/bin/jq; do
        [[ -x "$c" ]] && { JQ="$c"; break; }; done
    fi
    [[ -z "${JQ}" ]] && exit 0   # no jq -> skip (fail-soft); caller logs warn

    # Per-file hashes via STDIN (a confined jq cannot open files by path).
    gen_json="{}"; anc_json="{}"
    [[ -f "${QC_DIR}/genome_checksums.tsv" ]] && gen_json=$("${JQ}" -Rn \
      '[inputs|select(length>0)|split("\t")|{(.[0]):{sha256:.[1],bytes:.[2]}}]|add // {}' \
      < "${QC_DIR}/genome_checksums.tsv")
    [[ -f "${QC_DIR}/ancestor_checksums.tsv" ]] && anc_json=$("${JQ}" -Rn \
      '[inputs|select(length>0)|split("\t")|{(.[0]):{sha256:.[1],bp:.[2],n_fraction:(.[3]//"NA")}}]|add // {}' \
      < "${QC_DIR}/ancestor_checksums.tsv")
    [[ "${gen_json}" == [\{\[]* ]] || gen_json="{}"
    [[ "${anc_json}" == [\{\[]* ]] || anc_json="{}"

    # repro{}: canonical (sorted-key, compact) so its sha256 is stable.
    repro=$("${JQ}" -S -cn \
      --arg cac "${cactus_v}" --arg sam "${samtools_v}" --arg sif "${sif_digest}" \
      --arg seed "${CACTUS_SEED-0}" --argjson seedact "${seed_active}" \
      --arg newick "${NEWICK_TREE}" --arg region "${TEST_REGION_LEN}" \
      --arg lock "${lock_sha}" --arg sqt "${seqf_test}" --arg sqf "${seqf_full}" \
      --arg halt "${hal_test}" --arg half "${hal_full}" \
      --argjson genomes "${gen_json}" --argjson anc "${anc_json}" \
      '{cactus:$cac, cactus_seed:$seed, cactus_seed_active:$seedact,
        samtools:$sam, sif_sha256:$sif, toolchain_lock_sha256:$lock,
        newick:$newick, test_region_len:$region,
        inputs:{genomes:$genomes, seqfile_test_sha256:$sqt, seqfile_full_sha256:$sqf},
        outputs:{test_hal_sha256:$halt, full_hal_sha256:$half, ancestors:$anc}}')
    [[ "${repro}" == [\{]* ]] || exit 0
    repro_sha=$(printf '%s' "${repro}" | sha256sum | cut -d' ' -f1)

    meta=$("${JQ}" -S -cn \
      --arg run_id "${RUN_ID}" --arg ts "$(date -Iseconds)" --arg ns "${RUN_NS:-}" \
      --arg host "$(hostname)" --arg app "${apptainer_v}" \
      --arg sess "${llm_session}" --arg ag "${llm_agent}" --arg eff "${llm_effort}" --arg mdl "${llm_model}" \
      --arg sb "${sandboxed_eff}" \
      '{run_id:$run_id, timestamp:$ts, namespace:$ns, host:$host, apptainer:$app, sandboxed:$sb,
        llm:{session_id:$sess, agent:$ag, effort:$eff, model_id:$mdl,
             note:"LLM reasoning is non-deterministic and not repo-controllable; auditable only."}}')

    "${JQ}" -S -n --argjson repro "${repro}" --arg rsha "${repro_sha}" --argjson meta "${meta}" \
      '{schema:2, repro:$repro, repro_sha256:$rsha, meta:$meta}' > "${out}"
  )
  if [[ -s "${out}" ]]; then
    log_ok "Run manifest written: $(sanitize_path "${out}")"
  else
    log_warn "Run manifest could not be written (best-effort provenance skipped)."
  fi
  return 0
}

# ── Script banner ─────────────────────────────────────────────────────────
script_banner() {
  local name="$1"
  echo ""
  echo -e "${BOLD}========================================${NC}"
  echo -e "${BOLD}  ${name}${NC}"
  echo -e "${BOLD}  $(date)${NC}"
  echo -e "${BOLD}  run ${RUN_ID}${NC}"
  echo -e "${BOLD}========================================${NC}"
  echo ""
}

# ── Ensure dirs exist on source ──────────────────────────────────────────
ensure_dirs
