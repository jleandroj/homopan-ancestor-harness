#!/usr/bin/env bash
# run_supervised.sh -- run a HomoPan pipeline ENTIRELY inside the harness
# supervisor. This is the production entrypoint: every action is wrapped by the
# supervisor (unique run id, append-only + tamper-evident audit log, allowlist,
# timeout, kill-switch, resource limits, retry, and an automatic report on
# success OR failure).
#
#   bash scripts/run_supervised.sh test         # supervised test pipeline
#   bash scripts/run_supervised.sh full         # supervised full pipeline
#
# The harness gives the run-level envelope (audit/report/contain/kill); the
# pipeline keeps sandboxing its OWN compute steps via config.sh (P0.2), so we do
# NOT double-sandbox here (HARNESS_SANDBOX=0) to avoid nesting bwrap-in-bwrap.
# Override any HARNESS_* / HOMOPAN_* knob from the environment.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mode="${1:?usage: run_supervised.sh {test|full} [extra args]}"; shift || true
case "${mode}" in
  test) target="run_all_test.sh" ;;
  full) target="run_all_full.sh" ;;
  *)    echo "usage: run_supervised.sh {test|full}" >&2; exit 2 ;;
esac

# Production defaults (all overridable). The pipeline self-sandboxes compute, so
# the supervisor envelope does not nest a sandbox around the whole orchestrator.
export HARNESS_SANDBOX="${HARNESS_SANDBOX:-0}"
export HARNESS_TIMEOUT="${HARNESS_TIMEOUT:-172800}"   # 48h hard ceiling for the run
export HARNESS_RETRIES="${HARNESS_RETRIES:-0}"        # the pipeline has per-step retries already
export HOMOPAN_REQUIRE_HARNESS=1                      # let the orchestrator know it is supervised

echo "[run_supervised] launching '${mode}' pipeline under the harness supervisor..." >&2
exec bash "${ROOT}/scripts/harness/harness.sh" run -- bash "${ROOT}/scripts/${target}" "$@"
