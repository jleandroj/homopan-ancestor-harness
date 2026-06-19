#!/usr/bin/env bash
# test_sandbox_failclosed.sh -- P0.2 regression: compute sandbox is FAIL-CLOSED.
# When a sandbox is requested but the host cannot provide one, the run must ABORT
# (not silently run unisolated). Running without isolation must be explicit and
# recorded (sandboxed:false). We force a probe failure with a non-existent bwrap.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="test_failclosed_$$"
pass=0; fail=0
ok(){ echo "  [PASS] $1"; pass=$((pass+1)); }
no(){ echo "  [FAIL] $1"; fail=$((fail+1)); }
cleanup(){ rm -rf "${ROOT}/runs/${NS}" 2>/dev/null || true; }
trap cleanup EXIT

echo "sandbox compute fail-closed (P0.2)"
echo "════════════════════════════════════════"

# Source once in a throwaway namespace; force the probe to fail.
export HOMOPAN_RUN_NS="${NS}"
export HOMOPAN_BWRAP_BIN="/nonexistent/bwrap_${NS}"
# shellcheck disable=SC1091
source "${ROOT}/scripts/config.sh" >/dev/null 2>&1

run_in_subshell() {  # <env assignments...> ; echoes "<rc>|<alive>|<recorded>"
  rm -f "${QC_DIR}/.sandbox_effective" 2>/dev/null || true
  local rc alive rec
  alive=$(
    env "$@" bash -c '
      source "'"${ROOT}"'/scripts/config.sh" >/dev/null 2>&1
      _sandbox_probe_cache=""
      if sandbox_compute_active >/dev/null 2>&1; then echo "SB"; else echo "NOSB"; fi
      echo "ALIVE"
    ' 2>/dev/null
  )
  rc=$?
  rec=$(cat "${QC_DIR}/.sandbox_effective" 2>/dev/null || echo "absent")
  printf '%s|%s|%s' "${rc}" "${alive//$'\n'/,}" "${rec}"
}

# 1. auto + probe-fail + no override -> ABORT (die). 'ALIVE' must NOT print.
r=$(run_in_subshell HOMOPAN_RUN_NS="${NS}" HOMOPAN_BWRAP_BIN="/nonexistent/x" HOMOPAN_SANDBOX_COMPUTE=auto)
[[ "${r}" != *"ALIVE"* ]] && ok "auto + probe-fail aborts (no fall-through): ${r}" \
  || no "auto + probe-fail should abort, but continued: ${r}"

# 2. forced=1 + probe-fail -> ABORT (die).
r=$(run_in_subshell HOMOPAN_RUN_NS="${NS}" HOMOPAN_BWRAP_BIN="/nonexistent/x" HOMOPAN_SANDBOX_COMPUTE=1)
[[ "${r}" != *"ALIVE"* ]] && ok "forced=1 + probe-fail aborts: ${r}" \
  || no "forced=1 should abort, but continued: ${r}"

# 3. auto + ALLOW_UNSANDBOXED=1 -> continue UNSANDBOXED, record sandboxed:false.
r=$(run_in_subshell HOMOPAN_RUN_NS="${NS}" HOMOPAN_BWRAP_BIN="/nonexistent/x" HOMOPAN_SANDBOX_COMPUTE=auto HOMOPAN_ALLOW_UNSANDBOXED=1)
[[ "${r}" == *"NOSB"* && "${r}" == *"ALIVE"* && "${r}" == *"|false" ]] \
  && ok "override runs unsandboxed + records sandboxed:false: ${r}" \
  || no "override should continue unsandboxed and record false: ${r}"

# 4. explicit opt-out =0 -> continue unsandboxed, record false, no die.
r=$(run_in_subshell HOMOPAN_RUN_NS="${NS}" HOMOPAN_BWRAP_BIN="/nonexistent/x" HOMOPAN_SANDBOX_COMPUTE=0)
[[ "${r}" == *"NOSB"* && "${r}" == *"ALIVE"* && "${r}" == *"|false" ]] \
  && ok "opt-out =0 records sandboxed:false: ${r}" \
  || no "opt-out =0 should record false: ${r}"

echo ""
echo "  Results: ${pass} passed, ${fail} failed"
(( fail == 0 )) && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
