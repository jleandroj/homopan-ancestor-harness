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

# Fix the run id so we know the run dir, then verify the run after it finishes.
export HARNESS_RUN_ID="${HARNESS_RUN_ID:-$(bash "${ROOT}/scripts/harness/harness.sh" id)}"
export HARNESS_BASE="${HARNESS_BASE:-${ROOT}/runs/_harness}"
run_dir="${HARNESS_BASE}/${HARNESS_RUN_ID}"

echo "[run_supervised] launching '${mode}' pipeline under the harness supervisor (run ${HARNESS_RUN_ID})..." >&2
bash "${ROOT}/scripts/harness/harness.sh" run -- bash "${ROOT}/scripts/${target}" "$@"
pipe_rc=$?

echo "[run_supervised] pipeline exit=${pipe_rc}; running the verification (evidence) layer..." >&2
verdict="$(bash "${ROOT}/scripts/verify_agents/assemble_and_verify.sh" "${run_dir}" 2>/dev/null | tail -1)"
echo "[run_supervised] DONE  pipeline_exit=${pipe_rc}  verification=${verdict:-UNKNOWN}" >&2
echo "[run_supervised] report: ${run_dir}/verify/REPORT.md" >&2

# Exit non-zero if the pipeline failed OR the evidence layer returned a hard FAIL
# (a technically-successful but unverified run must not look like success).
case "${verdict}" in FAIL_*) vfail=1 ;; *) vfail=0 ;; esac
(( pipe_rc != 0 || vfail != 0 )) && exit 1 || exit 0
