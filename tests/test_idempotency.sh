#!/usr/bin/env bash
# test_idempotency.sh -- Tests for input-hash-bound idempotency (config.sh)
# Verifies mark_done/is_done invalidate when declared inputs change.
# Runs entirely in a temp sandbox; does not touch real targets/.
# Run: bash tests/test_idempotency.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source the library under test (defines mark_done/is_done/step_inputs).
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/scripts/config.sh"
set +e   # config.sh enables errexit; the harness wants to keep running

RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
PASSED=0; FAILED=0
pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; ((PASSED++)) || true; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; ((FAILED++)) || true; }

# ── Sandbox: redirect markers + provide a controllable input file ─────────
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
TARGETS_DIR="${SANDBOX}/targets"
mkdir -p "${TARGETS_DIR}"

SMALL_INPUT="${SANDBOX}/small_input.txt"
echo "original content" > "${SMALL_INPUT}"

# Override the input map for synthetic steps (redefining is allowed in bash).
BIG_INPUT="${SANDBOX}/big.bin"
step_inputs() {
  case "$1" in
    teststep)    printf '%s\n' "${SMALL_INPUT}" ;;
    litstep)     printf '%s\n' "lit:TOKEN=${TEST_TOKEN:-A}" ;;
    bigstep)     printf '%s\n' "${BIG_INPUT}" ;;
    nodepsstep)  : ;;   # existence-only
    outstep)     printf '%s\n' "${SMALL_INPUT}" ;;
    *)           : ;;
  esac
}

# Override the output map: 'outstep' declares an output artifact so we can test
# output-fingerprint verification (corruption/truncation/deletion -> re-run).
OUT_ARTIFACT="${SANDBOX}/out.fa"
step_outputs() {
  case "$1" in
    outstep) printf '%s\n' "${OUT_ARTIFACT}" ;;
    *)       : ;;
  esac
}

echo ""
echo -e "${BOLD}Idempotency Tests${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"

# ── 1. Fresh marker is recognized ─────────────────────────────────────────
echo ""; echo -e "${BOLD}1. Mark then check${NC}"
mark_done teststep >/dev/null
if is_done teststep >/dev/null 2>&1; then pass "is_done true right after mark_done"; else fail "is_done should be true after mark_done"; fi

# ── 2. Changed input (same size) invalidates via content hash ─────────────
echo ""; echo -e "${BOLD}2. Input content change invalidates${NC}"
echo "modified content" > "${SMALL_INPUT}"   # different content
if is_done teststep >/dev/null 2>&1; then fail "is_done should be FALSE after input changed"; else pass "input change detected (re-run forced)"; fi

# Re-marking with the new content makes it valid again.
mark_done teststep >/dev/null
if is_done teststep >/dev/null 2>&1; then pass "re-mark with new content -> done"; else fail "should be done after re-mark"; fi

# ── 3. Literal-token change invalidates ───────────────────────────────────
echo ""; echo -e "${BOLD}3. Config-token change invalidates${NC}"
TEST_TOKEN=A mark_done litstep >/dev/null
if TEST_TOKEN=A is_done litstep >/dev/null 2>&1; then pass "same token -> done"; else fail "same token should be done"; fi
if TEST_TOKEN=B is_done litstep >/dev/null 2>&1; then fail "changed token should invalidate"; else pass "token change detected"; fi

# ── 4. Existence-only step (no declared inputs) ───────────────────────────
echo ""; echo -e "${BOLD}4. Existence-only step${NC}"
mark_done nodepsstep >/dev/null
if is_done nodepsstep >/dev/null 2>&1; then pass "existence-only step done after mark"; else fail "existence-only step should be done"; fi

# ── 5. Legacy / no-schema marker is REJECTED (P0: no accept-as-done) ──────
echo ""; echo -e "${BOLD}5. Legacy / corrupt marker rejected${NC}"
echo "2026-01-01T00:00:00-00:00" > "${TARGETS_DIR}/teststep.done"   # old format, no schema
if is_done teststep >/dev/null 2>&1; then fail "legacy marker must NOT be accepted (would skip a step forever)"; else pass "legacy/no-schema marker rejected -> re-run"; fi
# A marker with the right schema but a blanked-out inputs hash is also rejected.
printf 'schema=2\ninputs_sha256=\noutputs_sha256=none\n' > "${TARGETS_DIR}/teststep.done"
if is_done teststep >/dev/null 2>&1; then fail "blank inputs hash must be rejected"; else pass "blank inputs hash rejected -> re-run"; fi
# Restore a valid marker for later tests.
mark_done teststep >/dev/null

# ── 6. Missing marker is not done ─────────────────────────────────────────
echo ""; echo -e "${BOLD}6. Missing marker${NC}"
rm -f "${TARGETS_DIR}/teststep.done"
if is_done teststep >/dev/null 2>&1; then fail "missing marker should be not-done"; else pass "missing marker -> not done"; fi

# ── 7. Marker records an inputs_sha256 line ───────────────────────────────
echo ""; echo -e "${BOLD}7. Marker format${NC}"
mark_done teststep >/dev/null
if grep -qE '^inputs_sha256=[0-9a-f]{64}$' "${TARGETS_DIR}/teststep.done"; then
  pass "marker contains a real inputs_sha256"
else
  fail "marker missing inputs_sha256 line"
fi

# ── 8. Large file: sampled fingerprint detects content edits ──────────────
echo ""; echo -e "${BOLD}8. Large-file sampled fingerprint${NC}"
head -c 60000000 /dev/zero > "${BIG_INPUT}" 2>/dev/null   # 60 MB (> 50 MB threshold)
mark_done bigstep >/dev/null
if is_done bigstep >/dev/null 2>&1; then pass "large file done after mark"; else fail "large file should be done"; fi
printf 'X' | dd of="${BIG_INPUT}" bs=1 seek=0 conv=notrunc 2>/dev/null   # edit first byte (sampled head)
if is_done bigstep >/dev/null 2>&1; then fail "edit in large file should invalidate (sampled)"; else pass "large-file content edit detected"; fi

# ── 9. Atomic write / crash-recovery: mark_done leaves no stray .tmp ──────
echo ""; echo -e "${BOLD}9. Atomic marker write (crash-recovery)${NC}"
mark_done teststep >/dev/null
shopt -s nullglob; stray=( "${TARGETS_DIR}"/*.tmp ); shopt -u nullglob
(( ${#stray[@]} == 0 )) && pass "no stray .tmp after mark_done (atomic mv)" || fail "left ${#stray[@]} stray .tmp file(s)"
grep -qE '^schema=2$' "${TARGETS_DIR}/teststep.done" && pass "marker carries schema=2" || fail "marker missing schema=2"
# Simulate a crash mid-write: a half-written .tmp must be ignored by is_done.
printf 'schema=2\ntimestamp=partial' > "${TARGETS_DIR}/crashstep.done.partial.tmp"
if is_done crashstep >/dev/null 2>&1; then fail "a .tmp must never count as a completed marker"; else pass "half-written .tmp ignored (step re-runs)"; fi

# ── 10. Output verification: corruption/truncation/deletion forces re-run ─
echo ""; echo -e "${BOLD}10. Output fingerprint verification${NC}"
echo "ancestor v1" > "${OUT_ARTIFACT}"
mark_done outstep >/dev/null
if is_done outstep >/dev/null 2>&1; then pass "step done with intact output"; else fail "should be done with intact output"; fi
grep -qE '^outputs_sha256=[0-9a-f]{64}$' "${TARGETS_DIR}/outstep.done" && pass "marker records a real outputs_sha256" || fail "marker missing outputs_sha256"
echo "corrupted" > "${OUT_ARTIFACT}"        # mutate output after completion
if is_done outstep >/dev/null 2>&1; then fail "changed output must invalidate"; else pass "changed/truncated output detected -> re-run"; fi
mark_done outstep >/dev/null; rm -f "${OUT_ARTIFACT}"   # delete output after completion
if is_done outstep >/dev/null 2>&1; then fail "deleted output must invalidate"; else pass "deleted output detected -> re-run"; fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD}  Results: ${PASSED} passed, ${FAILED} failed${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo ""
(( FAILED == 0 )) || { echo -e "${RED}${BOLD}TESTS FAILED${NC}"; exit 1; }
echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"; exit 0
