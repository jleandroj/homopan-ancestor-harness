#!/usr/bin/env bash
# test_sandbox.sh -- P0 tests for the real isolation boundary (sandbox_run.sh).
# Validates: network containment (no egress by default; ALLOW_NET exposes host
# interfaces) and host-secret confidentiality (no $HOME, env cleared).
# Run: bash tests/test_sandbox.sh
set -uo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="${SRC_ROOT}/scripts/sandbox_run.sh"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
PASSED=0; FAILED=0
pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; ((PASSED++)) || true; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; ((FAILED++)) || true; }

if ! command -v bwrap >/dev/null 2>&1; then
  echo -e "  ${YELLOW}[SKIP]${NC} bubblewrap (bwrap) not installed"; exit 0
fi

echo ""
echo -e "${BOLD}Sandbox Boundary Tests${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"

# ── 1. Network containment ────────────────────────────────────────────────
echo ""; echo -e "${BOLD}1. Network containment${NC}"
# Only loopback visible by default
n_def=$(bash "${SB}" bash -c 'awk -F: "NF>1 && \$1 !~ /Inter|face/ {print \$1}" /proc/net/dev | wc -l' 2>/dev/null | tr -d ' ')
[[ "${n_def}" == "1" ]] && pass "default: only loopback interface (no egress namespace)" || fail "default should expose only lo, got ${n_def} interfaces"
# External TCP connect must fail
out=$(bash "${SB}" bash -c 'timeout 3 bash -c "exec 3<>/dev/tcp/1.1.1.1/53" 2>/dev/null && echo OPEN || echo BLOCKED' 2>/dev/null)
[[ "${out}" == "BLOCKED" ]] && pass "external TCP connect blocked (--unshare-net)" || fail "external connect not blocked: ${out}"
# ALLOW_NET exposes host interfaces
n_net=$(HOMOPAN_ALLOW_NET=1 bash "${SB}" bash -c 'awk -F: "NF>1 && \$1 !~ /Inter|face/ {print \$1}" /proc/net/dev | wc -l' 2>/dev/null | tr -d ' ')
(( n_net > n_def )) && pass "HOMOPAN_ALLOW_NET=1 exposes host network (${n_net} ifaces)" || fail "ALLOW_NET should expose more ifaces (got ${n_net} vs ${n_def})"

# ── 2. Confidentiality: host secrets unreachable ──────────────────────────
echo ""; echo -e "${BOLD}2. Confidentiality${NC}"
SECRET="${HOME}/.homopan_secret_probe.$$"
echo "TOPSECRET-$$" > "${SECRET}"
trap 'rm -f "${SECRET}"' EXIT
# File in $HOME must not be readable inside (no /home bound, HOME=/tmp)
out=$(bash "${SB}" cat "${SECRET}" 2>&1); rc=$?
if (( rc != 0 )) && ! grep -q "TOPSECRET" <<<"${out}"; then
  pass "host \$HOME file unreadable inside sandbox"
else
  fail "host secret LEAKED into sandbox (rc=${rc})"
fi
# ~/.ssh keys unreachable
out=$(bash "${SB}" bash -c 'cat ~/.ssh/* 2>&1' 2>&1)
grep -q "PRIVATE KEY" <<<"${out}" && fail "~/.ssh private key readable inside sandbox" || pass "~/.ssh unreachable inside sandbox"
# Environment cleared
export HOMOPAN_PROBE_SECRET="leaky-$$"
val=$(bash "${SB}" bash -c 'echo "${HOMOPAN_PROBE_SECRET:-CLEARED}"' 2>/dev/null)
[[ "${val}" == "CLEARED" ]] && pass "exported env secret cleared (--clearenv)" || fail "env secret leaked: ${val}"
# Opt-in passthrough still works
val=$(HOMOPAN_PASS_ENV=HOMOPAN_PROBE_SECRET bash "${SB}" bash -c 'echo "${HOMOPAN_PROBE_SECRET:-CLEARED}"' 2>/dev/null)
[[ "${val}" == "leaky-$$" ]] && pass "HOMOPAN_PASS_ENV passes a chosen var through" || fail "PASS_ENV passthrough failed: ${val}"

# ── 3. Project IS writable inside ─────────────────────────────────────────
echo ""; echo -e "${BOLD}3. Project usable inside${NC}"
probe="${SRC_ROOT}/work/.sandbox_write_probe.$$"
bash "${SB}" bash -c "echo ok > '${probe}'" 2>/dev/null
[[ -f "${probe}" ]] && { pass "work dir writable inside sandbox"; rm -f "${probe}"; } || fail "work dir not writable inside sandbox"

# ── 4. Fail-closed default (no unsandboxed fallback) ──────────────────────
echo ""; echo -e "${BOLD}4. Fail-closed default${NC}"
out=$(HOMOPAN_BWRAP_BIN=__no_such_bwrap__ bash "${SB}" /bin/true 2>&1); rc=$?
(( rc == 3 )) && pass "refuses to run when bwrap unavailable (exit 3)" || fail "should fail-closed without bwrap (rc=${rc})"
HOMOPAN_BWRAP_BIN=__no_such_bwrap__ HOMOPAN_ALLOW_UNSANDBOXED=1 bash "${SB}" /bin/true 2>/dev/null \
  && pass "HOMOPAN_ALLOW_UNSANDBOXED=1 permits unsandboxed run" || fail "ALLOW_UNSANDBOXED should permit run"

echo ""
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD}  Results: ${PASSED} passed, ${FAILED} failed${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo ""
(( FAILED == 0 )) || { echo -e "${RED}${BOLD}TESTS FAILED${NC}"; exit 1; }
echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"; exit 0
