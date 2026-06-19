#!/usr/bin/env bash
# test_jobstore_guard.sh -- Tests the jobstore<->inputs guard (P1-f) that
# prevents Cactus --restart against a jobstore built from different inputs.
# Synthetic: exercises config.sh helpers without running Cactus.
# Run: bash tests/test_jobstore_guard.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/scripts/config.sh"
set +e

RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
PASSED=0; FAILED=0
pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; ((PASSED++)) || true; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; ((FAILED++)) || true; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "${SANDBOX}"' EXIT
JS="${SANDBOX}/js-test"; mkdir -p "${JS}"
SEQ="${SANDBOX}/seq.txt"; echo "v1 inputs" > "${SEQ}"

# Synthetic step whose declared input is our controllable seqfile.
step_inputs() { case "$1" in jobstep) printf '%s\n' "${SEQ}";; *) :;; esac; }

echo ""
echo -e "${BOLD}Jobstore Guard Tests${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"

# ── 1. No sidecar yet -> "unknown" (rc 2) ─────────────────────────────────
echo ""; echo -e "${BOLD}1. Legacy jobstore (no record)${NC}"
rc=0; check_jobstore_inputs "${JS}" jobstep || rc=$?
(( rc == 2 )) && pass "no sidecar -> rc 2 (legacy)" || fail "expected rc 2, got ${rc}"

# ── 2. After recording, same inputs -> match (rc 0) ───────────────────────
echo ""; echo -e "${BOLD}2. Same inputs match${NC}"
record_jobstore_inputs "${JS}" jobstep
[[ -f "${JS}.inputs" ]] && pass "sidecar written" || fail "sidecar missing"
rc=0; check_jobstore_inputs "${JS}" jobstep || rc=$?
(( rc == 0 )) && pass "unchanged inputs -> rc 0 (restart ok)" || fail "expected rc 0, got ${rc}"

# ── 3. Changed inputs -> mismatch (rc 1) ──────────────────────────────────
echo ""; echo -e "${BOLD}3. Changed inputs mismatch${NC}"
echo "v2 DIFFERENT inputs" > "${SEQ}"
rc=0; check_jobstore_inputs "${JS}" jobstep || rc=$?
(( rc == 1 )) && pass "changed inputs -> rc 1 (refuse restart)" || fail "expected rc 1, got ${rc}"

# ── 4. Re-record realigns -> match again ──────────────────────────────────
echo ""; echo -e "${BOLD}4. Re-record realigns${NC}"
record_jobstore_inputs "${JS}" jobstep
rc=0; check_jobstore_inputs "${JS}" jobstep || rc=$?
(( rc == 0 )) && pass "re-record -> rc 0" || fail "expected rc 0, got ${rc}"

echo ""
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD}  Results: ${PASSED} passed, ${FAILED} failed${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo ""
(( FAILED == 0 )) || { echo -e "${RED}${BOLD}TESTS FAILED${NC}"; exit 1; }
echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"; exit 0
