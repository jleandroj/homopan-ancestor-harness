#!/usr/bin/env bash
# test_egress.sh -- egress allowlist wrappers (scripts/net_wrappers/).
# Validates default-deny, allowlisted pass-through, raw-IP deny, and
# config-file / stdin-config inspection. Run: bash tests/test_egress.sh
set -uo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURL="${SRC_ROOT}/scripts/net_wrappers/curl"
RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
PASSED=0; FAILED=0
pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; ((PASSED++)) || true; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; ((FAILED++)) || true; }

SBX="$(mktemp -d)"; trap 'rm -rf "${SBX}"' EXIT
export HOMOPAN_EGRESS_ALLOWLIST="${SBX}/allow.txt"
printf 'example.com\n' > "${HOMOPAN_EGRESS_ALLOWLIST}"

# exit 7 == egress denied by the guard (before reaching real curl)
denied() { bash "${CURL}" "$@" >/dev/null 2>&1; [[ $? -eq 7 ]]; }
allowed_guard() { bash "${CURL}" --max-time 1 "$@" >/dev/null 2>&1; [[ $? -ne 7 ]]; }

echo ""
echo -e "${BOLD}Egress Allowlist Tests${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo ""

denied https://evil.example.org/x        && pass "unlisted host denied"            || fail "unlisted host should be denied"
denied http://malware.test/a             && pass "another unlisted host denied"    || fail "should deny"
denied https://140.82.112.3/x            && pass "raw IP denied"                    || fail "raw IP should be denied"
denied -K -                              && pass "stdin config (-K -) denied"       || fail "stdin config should be denied"

# config file pointing at an unlisted host
echo 'url = "https://evil.example.org/p"' > "${SBX}/bad.cfg"
denied --config "${SBX}/bad.cfg"         && pass "config file w/ unlisted host denied" || fail "config file deny"

# allowlisted host passes the GUARD (real curl then runs; exit != 7)
allowed_guard https://example.com/       && pass "allowlisted host passes the guard"    || fail "allowlisted host should pass guard"
echo 'url = "https://example.com/ok"' > "${SBX}/ok.cfg"
allowed_guard --config "${SBX}/ok.cfg"   && pass "config file w/ allowlisted host passes" || fail "good config should pass"

echo ""
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD}  Results: ${PASSED} passed, ${FAILED} failed${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo ""
(( FAILED == 0 )) || { echo -e "${RED}${BOLD}TESTS FAILED${NC}"; exit 1; }
echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"; exit 0
