#!/usr/bin/env bash
# replay_run.sh -- reconstruct a past run from its immutable manifest and re-run
# it in a FRESH namespace, then confirm the reproduced test artifact matches the
# manifest. Idempotent: a fresh NS + the existing .done markers mean no
# duplicated effects.
#
# Usage: bash scripts/replay_run.sh <run_id> [target_ns]
#        bash scripts/replay_run.sh --list
#
# What it pins from the manifest: CACTUS_SEED (effective seed) and the recorded
# input genome sha256s (re-verified, fail-closed on drift). The Newick tree and
# SIF are pinned by config/init already. The LLM layer is NOT replayed -- only
# the deterministic Cactus/HAL compute is (see REPRODUCIBILITY.md).
set -uo pipefail
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SRC_ROOT}/scripts/config.sh"

find_manifest() {  # <run_id> -> path or empty
  local rid="$1" m
  for m in "${SRC_ROOT}"/runs/*/qc/manifests/"${rid}".json \
           "${SRC_ROOT}"/qc/manifests/"${rid}".json; do
    [[ -f "$m" ]] && { printf '%s' "$m"; return 0; }
  done
  return 1
}

if [[ "${1:-}" == "--list" ]]; then
  echo "Available run manifests:"
  ls -1 "${SRC_ROOT}"/runs/*/qc/manifests/*.json "${SRC_ROOT}"/qc/manifests/*.json 2>/dev/null \
    | sed 's|.*/||;s|\.json$||' | sort -u | sed 's/^/  /' || echo "  (none)"
  exit 0
fi

RID="${1:?usage: replay_run.sh <run_id> [target_ns] (or --list)}"
MAN="$(find_manifest "${RID}")" || die "No manifest for run_id '${RID}'. Try: bash scripts/replay_run.sh --list"
log_ok "Found manifest: $(sanitize_path "${MAN}")"

# jq routed to a capable build by config.sh; read manifest via stdin.
SEED=$(jq -r '.repro.cactus_seed // "0"' < "${MAN}")
NEWICK_REC=$(jq -r '.repro.newick // ""' < "${MAN}")
HAL_REC=$(jq -r '.repro.outputs.test_hal_sha256 // ""' < "${MAN}")
log_info "Recorded: cactus_seed=${SEED}, test_hal_sha256=${HAL_REC:0:16}..."

# ── Input integrity: recorded genome shas must match the genomes on disk ────
if [[ "${HOMOPAN_REPLAY_SKIP_INPUT_CHECK:-0}" != "1" ]]; then
  log_step "Verifying input genomes against the manifest (fail-closed on drift)"
  drift=0
  while IFS=$'\t' read -r name sha; do
    [[ -z "${name}" ]] && continue
    fa="${GENOMES_DIR}/${name}.fa"
    if [[ ! -f "${fa}" ]]; then log_error "input ${name}.fa missing"; drift=1; continue; fi
    cur=$(compute_sha256 "${fa}")
    if [[ "${cur}" != "${sha}" ]]; then
      log_error "input drift ${name}.fa: manifest=${sha:0:16}... disk=${cur:0:16}..."; drift=1
    else
      log_ok "input ${name}.fa matches (${sha:0:16}...)"
    fi
  done < <(jq -r '.repro.inputs.genomes | to_entries[] | "\(.key)\t\(.value.sha256)"' < "${MAN}")
  if (( drift )); then
    die "Input genomes differ from the manifest. Replay aborted (set HOMOPAN_REPLAY_SKIP_INPUT_CHECK=1 to override)."
  fi
else
  log_warn "Input integrity check skipped (HOMOPAN_REPLAY_SKIP_INPUT_CHECK=1)."
fi

# Sanity: the recorded tree must match the current config tree (else not the same experiment).
if [[ -n "${NEWICK_REC}" && "${NEWICK_REC}" != "${NEWICK_TREE}" ]]; then
  die "Newick tree in manifest differs from current config.sh NEWICK_TREE. Replay would not reproduce the same run."
fi

# ── Re-run in a fresh namespace with the recorded seed ─────────────────────
NS="${2:-replay_${RID}}"
log_step "Replaying into namespace '${NS}' (seed=${SEED})"
if ! HOMOPAN_RUN_NS="${NS}" CACTUS_SEED="${SEED}" bash "${SRC_ROOT}/scripts/run_all_test.sh"; then
  die "Replay pipeline failed in namespace '${NS}'."
fi

# ── Confirm reproduction (fail-closed: divergence is a non-zero exit) ───────
# By default a byte-divergent replay EXITS NON-ZERO so callers/CI can trust the
# verdict. Because the container's Cactus is known non-deterministic (see
# REPRODUCIBILITY.md), set HOMOPAN_REPLAY_ALLOW_DIVERGENCE=1 to downgrade
# divergence to a warning (exit 0) and acknowledge it as expected.
rc=0
NEW_HAL="${SRC_ROOT}/runs/${NS}/results/test/primates.test.hal"
if [[ -n "${HAL_REC}" && -f "${NEW_HAL}" ]]; then
  NEW_SHA=$(compute_sha256 "${NEW_HAL}")
  if [[ "${NEW_SHA}" == "${HAL_REC}" ]]; then
    log_ok "REPLAY REPRODUCED: test HAL sha256 matches the manifest (${NEW_SHA:0:16}...)."
  elif [[ "${HOMOPAN_REPLAY_ALLOW_DIVERGENCE:-0}" == "1" ]]; then
    log_warn "Replay test HAL DIVERGES (recorded=${HAL_REC:0:16}... new=${NEW_SHA:0:16}...); accepted (HOMOPAN_REPLAY_ALLOW_DIVERGENCE=1)."
    log_warn "Expected: Cactus is non-deterministic. Use repro_verify.sh for the equivalence metric."
  else
    log_error "REPLAY DID NOT REPRODUCE: test HAL sha256 DIFFERS (recorded=${HAL_REC:0:16}... new=${NEW_SHA:0:16}...)."
    log_error "Set HOMOPAN_REPLAY_ALLOW_DIVERGENCE=1 to accept (Cactus is non-deterministic), or run repro_verify.sh to classify."
    rc=2
  fi
else
  log_warn "No recorded test_hal_sha256 to compare (original may have been a full-only run)."
fi
log_info "Replay namespace kept at $(sanitize_path "${SRC_ROOT}/runs/${NS}") for inspection."
echo "Caveat: ancestors are inferred; the 1 Mb test path is technical, not biological."
exit "${rc}"
