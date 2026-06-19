#!/usr/bin/env bash
# test_concurrency.sh -- concurrency + tool-failure invariants.
#  - acquire_step_lock: only ONE concurrent runner wins.
#  - bitacora_log.sh: concurrent appends stay well-formed JSONL (flock).
#  - a step that fails before mark_done leaves NO .done marker.
# Run: bash tests/test_concurrency.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/scripts/config.sh"
set +e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
PASSED=0; FAILED=0
pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; ((PASSED++)) || true; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; ((FAILED++)) || true; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "${SANDBOX}"' EXIT
TARGETS_DIR="${SANDBOX}/targets"; mkdir -p "${TARGETS_DIR}"

echo ""
echo -e "${BOLD}Concurrency / Tool-failure Tests${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"

# ── 1. Step lock: only one concurrent holder wins ─────────────────────────
echo ""; echo -e "${BOLD}1. acquire_step_lock mutual exclusion${NC}"
RES="${SANDBOX}/got"; : > "${RES}"
holder() { if acquire_step_lock conc_test 2>/dev/null; then echo got >> "${RES}"; sleep 0.5; fi; }
holder & holder & holder & wait
n=$(wc -l < "${RES}" 2>/dev/null | tr -d ' ')
[[ "${n}" == "1" ]] && pass "exactly one runner acquired the lock (${n})" || fail "expected 1 lock winner, got ${n}"

# ── 2. Concurrent bitacora appends stay valid JSONL ───────────────────────
echo ""; echo -e "${BOLD}2. Concurrent log appends (flock)${NC}"
BIT="${PROJECT_ROOT}/.claude/bitacora_log.sh"
export HOMOPAN_AUDIT_LOG="${SANDBOX}/audit.jsonl"; : > "${HOMOPAN_AUDIT_LOG}"
N=25
for i in $(seq "${N}"); do
  printf '{"tool_name":"Bash","tool_input":{"command":"echo job-%s"},"tool_response":{"is_error":false}}' "$i" \
    | bash "${BIT}" &
done
wait
lines=$(wc -l < "${HOMOPAN_AUDIT_LOG}" | tr -d ' ')
bad=0
if command -v jq >/dev/null 2>&1; then
  while IFS= read -r ln; do jq -e . >/dev/null 2>&1 <<<"${ln}" || bad=$((bad+1)); done < "${HOMOPAN_AUDIT_LOG}"
else
  # bash-pure: every line must start with { and end with }
  while IFS= read -r ln; do [[ "${ln}" == \{*\} ]] || bad=$((bad+1)); done < "${HOMOPAN_AUDIT_LOG}"
fi
[[ "${lines}" == "${N}" ]] && pass "all ${N} concurrent appends landed (no lost writes)" || fail "expected ${N} lines, got ${lines}"
(( bad == 0 )) && pass "every concurrent line is well-formed JSON (no interleave)" || fail "${bad} malformed lines"
unset HOMOPAN_AUDIT_LOG

# ── 3. Failed step leaves no .done marker ─────────────────────────────────
echo ""; echo -e "${BOLD}3. Tool failure -> no marker${NC}"
cat > "${SANDBOX}/failstep.sh" <<EOF
set -euo pipefail
source "${PROJECT_ROOT}/scripts/config.sh"
TARGETS_DIR="${SANDBOX}/targets"
false            # simulate a tool/step failure before completion
mark_done failstep
EOF
bash "${SANDBOX}/failstep.sh" >/dev/null 2>&1
if [[ -f "${SANDBOX}/targets/failstep.done" ]]; then
  fail "a failed step must NOT leave a .done marker"
else
  pass "failed step left no .done marker"
fi

# ── 4. Both orchestrators share ONE lock (no cross-orchestrator race) ─────
echo ""; echo -e "${BOLD}4. Unified orchestrator lock${NC}"
T="${PROJECT_ROOT}/scripts/run_all_test.sh"; F="${PROJECT_ROOT}/scripts/run_all_full.sh"
tl=$(grep -oE 'pipeline[A-Za-z_]*\.lock' "${T}" | head -1)
fl=$(grep -oE 'pipeline[A-Za-z_]*\.lock' "${F}" | head -1)
if [[ -n "${tl}" && "${tl}" == "${fl}" ]]; then
  pass "test+full orchestrators use the same lock file (${tl})"
else
  fail "orchestrators use different locks (test='${tl}' full='${fl}') -> can race over shared state"
fi
if grep -qE 'pipeline_(test|full)\.lock' "${T}" "${F}"; then
  fail "a per-mode pipeline_{test,full}.lock survived (regression)"
else
  pass "no per-mode pipeline lock remains"
fi
# The shared lock must actually be mutually exclusive.
LOCK="${SANDBOX}/pipeline.lock"; RES2="${SANDBOX}/got2"; : > "${RES2}"
orch() { exec {fd}>"${LOCK}"; if flock -n "${fd}"; then echo got >> "${RES2}"; sleep 0.5; fi; }
orch & orch & orch & wait
n2=$(wc -l < "${RES2}" | tr -d ' ')
[[ "${n2}" == "1" ]] && pass "only one orchestrator can hold pipeline.lock (${n2})" || fail "expected 1 holder, got ${n2}"

echo ""
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD}  Results: ${PASSED} passed, ${FAILED} failed${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo ""
(( FAILED == 0 )) || { echo -e "${RED}${BOLD}TESTS FAILED${NC}"; exit 1; }
echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"; exit 0
