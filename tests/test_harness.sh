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

echo ""
echo "  Results: ${pass} passed, ${fail} failed"
(( fail == 0 )) && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
