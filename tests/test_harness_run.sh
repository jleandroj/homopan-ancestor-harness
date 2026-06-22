#!/usr/bin/env bash
# test_harness_run.sh -- harness_run.sh: audit, traceability, capture, report,
# retries, kill-switch. Isolated (own audit log + state under a temp HOME-ish).
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hr.XXXXXX")"; trap 'rm -rf "${TMP}"' EXIT
AUD="${TMP}/audit.jsonl"
HR(){ HARNESS_AUDIT_LOG="${AUD}" HARNESS_SANDBOX=0 bash "${SRC}/scripts/harness_run.sh" "$@"; }
fail=0; ck(){ [[ "$1" == "$2" ]] && echo "  [PASS] $3" || { echo "  [FAIL] $3 (got '$1' want '$2')"; fail=1; }; }

# 1. basic run: exit 0, output surfaced, audit start+end lines written
out="$(HR --label t1 -- echo hola 2>/dev/null)"
ck "$out" "hola" "stdout surfaced to caller"
ck "$(grep -c '"event":"start"' "${AUD}")" "1" "audit has a start line"
ck "$(grep -c '"event":"end"' "${AUD}")" "1" "audit has an end line"
ck "$(grep -c '"ok":true' "${AUD}")" "1" "end line records ok:true"

# 2. run_id present + duration recorded
grep -q '"run_id":"' "${AUD}"; ck "$?" "0" "run_id present (traceability)"
grep -q '"dur_ms":[0-9]' "${AUD}"; ck "$?" "0" "duration recorded"

# 3. failing command: harness survives, exit propagated, ok:false logged
HR --label t2 -- bash -c 'exit 7' >/dev/null 2>&1; rc=$?
ck "$rc" "7" "failing exit code propagated"
ck "$(grep -c '"ok":false' "${AUD}")" "1" "failure recorded ok:false"

# 4. retries: a command that fails is retried N times
HR --label t3 --retries 2 -- bash -c 'exit 3' >/dev/null 2>&1
ck "$(grep -c '"event":"retry"' "${AUD}")" "2" "2 retries logged"

# 5. input/output capture: output hash recorded and non-empty
grep -q '"out_sha256":"[0-9a-f]' "${AUD}"; ck "$?" "0" "output sha256 captured"

# 6. report generated per run
rid="$(grep -m1 '"label":"t1"' "${AUD}" | sed -E 's/.*"run_id":"([^"]+)".*/\1/')"
[[ -s "${SRC}/.harness/runs/${rid}/report.md" || -s "${SRC}/.harness/runs/${rid}/report.json" ]]; ck "$?" "0" "per-run report written"

# 7. kill-switch: refuses to run, exit 99
mkdir -p "${SRC}/.harness"; touch "${SRC}/.harness/KILL"
HR --label t4 -- echo nope >/dev/null 2>&1; rc=$?
rm -f "${SRC}/.harness/KILL"
ck "$rc" "99" "kill-switch refuses execution (exit 99)"

# 8. anomaly detection flags a secret-path command (still logged)
HR --label t5 -- bash -c 'echo ~/.ssh/id_rsa' >/dev/null 2>&1
grep -q '"anomalies":\[.*secret-path' "${AUD}"; ck "$?" "0" "secret-path anomaly detected"

echo ""; (( fail==0 )) && echo "test_harness_run: ALL PASS" || { echo "test_harness_run: FAILED"; exit 1; }
