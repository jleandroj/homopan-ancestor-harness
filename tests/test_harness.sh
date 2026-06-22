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

echo ""
echo "  Results: ${pass} passed, ${fail} failed"
(( fail == 0 )) && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
