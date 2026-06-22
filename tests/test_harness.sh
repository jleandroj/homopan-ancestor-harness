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

echo ""
echo "  Results: ${pass} passed, ${fail} failed"
(( fail == 0 )) && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
