#!/usr/bin/env bash
# test_harness.sh -- tests for the production supervisor (scripts/harness/harness.sh).
# Grows one block per iteration. Assumes BAD FAITH: the harness must catch agent
# misbehaviour, not trust it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="${ROOT}/scripts/harness/harness.sh"
pass=0; fail=0
ok(){ echo "  [PASS] $1"; pass=$((pass+1)); }
no(){ echo "  [FAIL] $1"; fail=$((fail+1)); }
# Repo-local temp: /tmp is shared and hostile (concurrent jobs, e.g. Toil/Cactus,
# reap /tmp dirs mid-test). The harness itself uses repo-local runs/ for the same
# reason. runs/ is gitignored.
mkdir -p "${ROOT}/runs"
TMP="$(mktemp -d "${ROOT}/runs/.htest.XXXXXX")"; trap 'rm -rf "${TMP}"' EXIT
export HARNESS_BASE="${TMP}/_harness"

echo "harness supervisor"
echo "════════════════════════════════════════"

# ── Iteration 1: run context + unique id + per-run dir ─────────────────────
id1="$(bash "${H}" id)"; id2="$(bash "${H}" id)"
[[ "${id1}" == run_*_* && "${id1}" != "${id2}" ]] && ok "run ids are well-formed and unique" || no "run id format/uniqueness: ${id1} ${id2}"
rd="$( source "${H}"; harness_init >/dev/null 2>&1; printf '%s' "${HARNESS_RUN_DIR}" )"
# jq via STDIN: the host jq may be the confined snap build (cannot open file-path
# args -> "Permission denied"); stdin is always safe. This is a project convention.
if [[ -n "${rd}" && -f "${rd}/run.json" ]] && jq -e '.run_id and .started_at and .git_commit' < "${rd}/run.json" >/dev/null 2>&1; then
  ok "harness_init writes valid run.json metadata"
else
  no "run.json missing/invalid (dir=${rd})"
fi

# ── Iteration 2: structured append-only audit log ─────────────────────────
audit="$( source "${H}"; harness_init >/dev/null 2>&1
          harness_log "start" phase "init"
          harness_log "action" cmd "echo hi" exit "0"
          printf '%s' "${HARNESS_RUN_DIR}/audit.jsonl" )"
if [[ -f "${audit}" ]] && [[ "$(wc -l < "${audit}")" == "2" ]] \
   && jq -e '.seq==1 and .type=="start"' < <(head -1 "${audit}") >/dev/null 2>&1 \
   && jq -e '.seq==2 and .type=="action" and .cmd=="echo hi"' < <(tail -1 "${audit}") >/dev/null 2>&1; then
  ok "audit.jsonl is valid JSONL, sequenced, ordered"
else
  no "audit log malformed (file=${audit})"
fi
# every line must be parseable JSON (no corruption)
if [[ -f "${audit}" ]] && while read -r l; do echo "$l" | jq -e . >/dev/null 2>&1 || exit 1; done < "${audit}"; then
  ok "every audit line is valid JSON"
else
  no "audit log has non-JSON lines"
fi

# ── Iteration 3: harness_exec captures I/O + duration + exit, returns rc ───
d="$( bash "${H}" run -- bash -c 'echo out; echo err >&2; exit 7' 2>/dev/null | sed -n 's/.*dir=\([^ ]*\).*/\1/p' )"
# (dir is printed to stderr; recapture)
d="$( bash "${H}" run -- bash -c 'echo out; echo err >&2; exit 7' 2>&1 >/dev/null | sed -n 's/.*dir=\([^ ]*\) .*/\1/p' )"
if [[ -n "${d}" && -f "${d}/audit.jsonl" ]]; then
  ae="$(grep '"type":"action_end"' "${d}/audit.jsonl" | tail -1)"
  echo "${ae}" | jq -e '.exit=="7" and (.duration_ms|tonumber>=0) and .outcome=="error"' >/dev/null 2>&1 \
    && ok "harness_exec records exit + duration + outcome" || no "action_end fields wrong: ${ae}"
  oid="$(echo "${ae}" | jq -r '.cmd' 2>/dev/null)"
  [[ -s "${d}/action_3.out" || -n "$(grep -l out "${d}"/action_*.out 2>/dev/null)" ]] && ok "stdout captured to file" || no "stdout not captured"
  grep -rq 'err' "${d}"/action_*.err 2>/dev/null && ok "stderr captured to file" || no "stderr not captured"
else
  no "run produced no run dir/audit (d=${d})"
fi
# exit code propagation
bash "${H}" run -- bash -c 'exit 0' >/dev/null 2>&1 && ok "harness run propagates exit 0" || no "exit 0 not propagated"
bash "${H}" run -- bash -c 'exit 3' >/dev/null 2>&1; [[ $? -eq 3 ]] && ok "harness run propagates non-zero exit" || no "non-zero exit not propagated"

# ── Iteration 4: deny-by-default allowlist ─────────────────────────────────
# allowed program (bash) runs; denied program (a fake binary) is refused + logged.
bash "${H}" run -- bash -c 'exit 0' >/dev/null 2>&1 && ok "allowlisted program runs" || no "allowlisted program blocked"
dd="$( bash "${H}" run -- /usr/bin/nc -h 2>&1 >/dev/null | sed -n 's/.*dir=\([^ ]*\) .*/\1/p' )"
rc_denied=$?
out2="$( HARNESS_ALLOWLIST_OFF= bash "${H}" run -- definitely_not_allowed_prog 2>&1 >/dev/null )"
rc2=$?
[[ ${rc2} -eq 126 ]] && ok "non-allowlisted program denied (exit 126)" || no "denied program not 126 (got ${rc2})"
echo "${out2}" | grep -q 'DENIED' && ok "denial surfaced to operator" || no "no DENIED message"
# the denial is in the audit log
d4="$( bash "${H}" run -- some_evil_binary 2>&1 >/dev/null | sed -n 's/.*dir=\([^ ]*\) .*/\1/p' )"
[[ -n "${d4}" ]] && grep -q '"type":"denied"' "${d4}/audit.jsonl" 2>/dev/null && ok "denial recorded in audit log" || no "denial not in audit log (d=${d4})"
# allowlist OFF lets it through (but is itself a logged choice)
HARNESS_ALLOWLIST_OFF=1 bash "${H}" run -- bash -c 'exit 0' >/dev/null 2>&1 && ok "HARNESS_ALLOWLIST_OFF=1 bypasses (explicit)" || no "OFF override failed"

# ── Iteration 5: timeout + kill-switch ─────────────────────────────────────
# a command that exceeds the timeout is killed and logged as timeout
d5="$( HARNESS_TIMEOUT=1 bash "${H}" run -- bash -c 'sleep 30' 2>&1 >/dev/null | sed -n 's/.*dir=\([^ ]*\) .*/\1/p' )"
if [[ -n "${d5}" ]] && grep -q '"type":"timeout"' "${d5}/audit.jsonl" 2>/dev/null; then
  ok "per-action timeout kills + logs timeout"
else
  no "timeout not enforced/logged (d=${d5})"
fi
# kill-switch: pre-set KILL via a fixed run id, then a run refuses to execute
ksdir="${TMP}/_harness/ks_run"; mkdir -p "${ksdir}"; : > "${ksdir}/KILL"
out5="$( HARNESS_RUN_ID=ks_run bash "${H}" run -- bash -c 'echo SHOULD_NOT_RUN' 2>&1 )"
rc5=$?
if [[ ${rc5} -eq 137 ]] && ! echo "${out5}" | grep -q SHOULD_NOT_RUN; then
  ok "kill-switch blocks execution (exit 137)"
else
  no "kill-switch did not block (rc=${rc5})"
fi
grep -q '"type":"killed"' "${ksdir}/audit.jsonl" 2>/dev/null && ok "kill recorded in audit log" || no "kill not logged"

# ── Iteration 6: resource limits ───────────────────────────────────────────
# a 1 MB file-size limit must make a 10 MB write fail (SIGXFSZ), and it's logged.
d6="$( HARNESS_LIM_FSIZE_MB=1 bash "${H}" run -- bash -c 'dd if=/dev/zero of=big.bin bs=1M count=10 2>/dev/null' 2>&1 >/dev/null | sed -n 's/.*dir=\([^ ]*\) .*/\1/p' )"
if [[ -n "${d6}" ]] && grep -q '"type":"limits"' "${d6}/audit.jsonl" 2>/dev/null; then
  ae6="$(grep '"type":"action_end"' "${d6}/audit.jsonl" | tail -1)"
  [[ "$(echo "${ae6}" | jq -r '.exit')" != "0" ]] && ok "rlimit (fsize) enforced -> action fails" || no "fsize limit not enforced: ${ae6}"
  echo "${ae6}" >/dev/null
  ok "limits recorded in audit log"
else
  no "limits not applied/logged (d=${d6})"
fi
rm -f big.bin 2>/dev/null

# ── Iteration 7: sandbox integration (fail-closed) ─────────────────────────
# On a host WITHOUT userns, requesting sandbox must DENY (fail-closed) unless
# explicitly overridden. We simulate "cannot sandbox" via a bogus bwrap.
out7="$( HARNESS_SANDBOX=1 HOMOPAN_BWRAP_BIN=/nonexistent/bwrap bash "${H}" run -- bash -c 'echo NOPE' 2>&1 )"
rc7=$?
if [[ ${rc7} -eq 126 ]] && ! echo "${out7}" | grep -q NOPE; then
  ok "sandbox requested + unavailable -> fail-closed DENY"
else
  no "sandbox not fail-closed (rc=${rc7})"
fi
# explicit override runs unsandboxed AND records it
d7="$( HARNESS_SANDBOX=1 HOMOPAN_BWRAP_BIN=/nonexistent/bwrap HARNESS_ALLOW_UNSANDBOXED=1 \
       bash "${H}" run -- bash -c 'exit 0' 2>&1 >/dev/null | sed -n 's/.*dir=\([^ ]*\) .*/\1/p' )"
[[ -n "${d7}" ]] && grep -q '"mode":"DISABLED-by-override"' "${d7}/audit.jsonl" 2>/dev/null \
  && ok "unsandboxed override runs + is recorded" || no "override not recorded (d=${d7})"

# ── Iteration 8: bounded retry + crash isolation ───────────────────────────
# a flaky action that fails then succeeds is retried; retries are logged.
d8="$( HARNESS_RETRIES=3 HARNESS_BACKOFF_S=0 bash "${H}" run -- bash -c '
  f="'"${TMP}"'/attempts"; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n+1)); echo $n >"$f"
  [[ $n -ge 2 ]]' 2>&1 >/dev/null | sed -n 's/.*dir=\([^ ]*\) .*/\1/p' )"
rc8=$?
if [[ -n "${d8}" ]] && grep -q '"type":"retry"' "${d8}/audit.jsonl" 2>/dev/null; then
  ok "failed action is retried (with logged attempts)"
  fe="$(grep '"type":"end"' "${d8}/audit.jsonl" | tail -1)"
  [[ "$(echo "${fe}" | jq -r '.exit')" == "0" ]] && ok "retry eventually succeeds -> exit 0" || no "retry final exit not 0: ${fe}"
else
  no "no retry recorded (d=${d8})"
fi
# a crashing action (kill -SEGV self) does NOT take down the harness; it's logged + reported
d8b="$( bash "${H}" run -- bash -c 'kill -SEGV $$' 2>&1 >/dev/null | sed -n 's/.*dir=\([^ ]*\) .*/\1/p' )"
[[ -n "${d8b}" ]] && grep -q '"type":"end"' "${d8b}/audit.jsonl" 2>/dev/null \
  && ok "action crash is contained; harness completes + logs end" || no "harness did not survive crash (d=${d8b})"
# policy denials are NOT retried
d8c="$( HARNESS_RETRIES=3 bash "${H}" run -- forbidden_prog 2>&1 >/dev/null | sed -n 's/.*dir=\([^ ]*\) .*/\1/p' )"
[[ -n "${d8c}" ]] && ! grep -q '"type":"retry"' "${d8c}/audit.jsonl" 2>/dev/null \
  && ok "policy denial is not retried" || no "denial was retried (d=${d8c})"

# ── Iteration 9: automatic report ──────────────────────────────────────────
d9="$( bash "${H}" run -- bash -c 'echo ok; exit 5' 2>&1 >/dev/null | sed -n 's/.*dir=\([^ ]*\) .*/\1/p' )"
if [[ -n "${d9}" && -f "${d9}/report.json" && -f "${d9}/report.md" ]]; then
  jq -e '.status=="PROBLEMS" and .errors==1 and .actions==1' < "${d9}/report.json" >/dev/null 2>&1 \
    && ok "report.json summarizes status + problems" || no "report.json wrong: $(cat "${d9}/report.json")"
  grep -q 'FAIL exit=5' "${d9}/report.md" && ok "report.md lists the failed action" || no "report.md missing failure"
else
  no "report not generated (d=${d9})"
fi
# clean run -> status OK
d9b="$( bash "${H}" run -- bash -c 'exit 0' 2>&1 >/dev/null | sed -n 's/.*dir=\([^ ]*\) .*/\1/p' )"
[[ -n "${d9b}" ]] && jq -e '.status=="OK" and .problems==0' < "${d9b}/report.json" >/dev/null 2>&1 \
  && ok "clean run reports status OK" || no "clean run not OK (d=${d9b})"

echo ""
echo "  Results: ${pass} passed, ${fail} failed"
(( fail == 0 )) && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
