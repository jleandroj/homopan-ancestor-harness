#!/usr/bin/env bash
# harness.sh -- production supervisor for agent/pipeline execution.
#
# Design goals (in priority order):
#   1. Complete audit log   -- every action logged (JSON, append-only, timestamped)
#   2. Automatic report     -- summary on success OR failure
#   3. Containment          -- nothing runs except through harness_exec (sandbox,
#                              rlimits, allowlist, timeout, kill-switch)
#   4. Traceability         -- unique run id; a past run is fully reconstructable
#   5. Robustness           -- errors caught; agent failure never kills the harness
#
# This file is a LIBRARY (source it) and a DRIVER:
#   source scripts/harness/harness.sh; harness_init; harness_exec -- mycmd args...
#   bash scripts/harness/harness.sh run -- mycmd args...
#
# Built iteratively; each iteration adds one capability and keeps it functional.
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "${HARNESS_DIR}/../.." && pwd)"

# ── Iteration 1: run context + unique id + per-run directory ───────────────
# A unique, sortable run id (UTC timestamp + pid + random) and an isolated
# directory hold everything about one supervised run, so any execution can be
# located and reconstructed later.
harness_runid() {
  local ts rnd
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  rnd="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%04x%04x' "${RANDOM}" "${RANDOM}")"
  printf 'run_%s_%s_%s' "${ts}" "$$" "${rnd}"
}

harness_init() {
  HARNESS_RUN_ID="${HARNESS_RUN_ID:-$(harness_runid)}"
  HARNESS_BASE="${HARNESS_BASE:-${HARNESS_ROOT}/runs/_harness}"
  HARNESS_RUN_DIR="${HARNESS_BASE}/${HARNESS_RUN_ID}"
  mkdir -p "${HARNESS_RUN_DIR}" || { echo "FATAL: cannot create run dir ${HARNESS_RUN_DIR}" >&2; return 1; }
  export HARNESS_RUN_ID HARNESS_RUN_DIR HARNESS_BASE
  # Immutable run metadata (best-effort fields; never fails the run).
  {
    printf '{'
    printf '"run_id":"%s",' "${HARNESS_RUN_ID}"
    printf '"started_at":"%s",' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '"host":"%s",' "$(hostname 2>/dev/null || echo unknown)"
    printf '"user":"%s",' "${USER:-$(id -un 2>/dev/null || echo unknown)}"
    printf '"pid":%s,' "$$"
    printf '"harness_version":"%s",' "${HARNESS_VERSION:-1}"
    printf '"git_commit":"%s",' "$(git -C "${HARNESS_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf '"cwd":"%s"' "${PWD}"
    printf '}\n'
  } > "${HARNESS_RUN_DIR}/run.json"
  return 0
}

# CLI: `harness.sh id` prints a fresh run id; `harness.sh init` sets up a run dir.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    id)   harness_runid ;;
    init) harness_init && echo "${HARNESS_RUN_DIR}" ;;
    *)    echo "usage: harness.sh {id|init}" >&2; exit 2 ;;
  esac
fi
