#!/usr/bin/env bash
# hreport.sh -- ITER 8: automatic per-run report on finish/fail.
# Called by harness_run.sh. Writes a human + JSON report under the run dir and
# notifies the user; on failure or anomalies it makes that loud.
# Args: <label> <exit_code> <dur_ms> <anomalies-space-sep> <run_id>
set -uo pipefail
LABEL="${1:-cmd}"; RC="${2:-0}"; DUR="${3:-0}"; ANOM="${4:-}"; RUN_ID="${5:-unknown}"
RUN_DIR="${HARNESS_RUN_DIR:-}"; [[ -z "${RUN_DIR}" ]] && exit 0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

status="OK"; (( RC == 0 )) || status="FAIL"
[[ -n "${ANOM// }" ]] && status="${status}+ANOMALY"

errtail="$(tail -c 800 "${RUN_DIR}/stderr.log" 2>/dev/null)"

# Markdown report (human)
{
  echo "# harness run report"
  echo "- run_id: ${RUN_ID}"
  echo "- label:  ${LABEL}"
  echo "- status: ${status}  (exit ${RC})"
  echo "- duration_ms: ${DUR}"
  echo "- anomalies: ${ANOM:-none}"
  echo "- run_dir: ${RUN_DIR}"
  echo "- audit: ${HARNESS_AUDIT_LOG:-${HOME}/.harness_audit.jsonl}"
  if (( RC != 0 )); then echo ""; echo "## stderr (tail)"; echo '```'; echo "${errtail}"; echo '```'; fi
} > "${RUN_DIR}/report.md"

# JSON report (machine)
printf '{"run_id":"%s","label":"%s","status":"%s","exit":%s,"dur_ms":%s,"anomalies":"%s"}\n' \
  "${RUN_ID}" "${LABEL}" "${status}" "${RC}" "${DUR}" "${ANOM}" > "${RUN_DIR}/report.json"

# session digest (append) so the user gets a per-session rollup too
DIGEST="${ROOT}/logs/session_digest.tsv"
printf '%s\t%s\t%s\t%s\t%sms\t%s\n' "$(date -Iseconds)" "${RUN_ID:0:8}" "${LABEL}" "${status}" "${DUR}" "${ANOM:-}" >> "${DIGEST}" 2>/dev/null || true

# loud notify on failure/anomaly
if [[ "${status}" != "OK" ]] && command -v notify-send >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
  notify-send -u critical "harness ${status}" "${LABEL} (exit ${RC}) ${ANOM:+[${ANOM}]} -- ${RUN_DIR}" >/dev/null 2>&1 || true
fi
exit 0
