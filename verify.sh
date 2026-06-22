#!/usr/bin/env bash
# verify.sh -- one-shot integrity check for the harness.
# Runs the self-tests, the full pre-flight gate (only when data is present),
# and reports working-tree cleanliness. Safe in a data-less / fresh checkout.
# Run: bash verify.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
fail=0

echo -e "${BOLD}HomoPan Harness -- verify.sh${NC}"
echo -e "${BOLD}========================================${NC}"

# ── 1. Harness self-tests (no genomes/SIF required) ───────────────────────
echo ""; echo -e "${BOLD}1. Self-tests${NC}"
for t in tests/test_idempotency.sh tests/test_jobstore_guard.sh tests/test_concurrency.sh tests/test_egress.sh tests/test_sandbox.sh tests/test_e2e_synthetic.sh tests/test_e2e_mock.sh tests/test_gate.sh tests/test_gate_exitcode.sh tests/test_gate_sandbox.sh tests/test_cmd_detector_fuzz.sh tests/test_skill_contracts.sh tests/test_quality_gate.sh tests/test_toolchain_lock.sh tests/test_manifest.sh tests/test_compare_runs.sh tests/test_repro_verify.sh tests/test_repro_verify_envfix.sh tests/test_sandbox_failclosed.sh tests/test_patch_idempotency.sh tests/test_patch_p1_idempotency.sh tests/test_cmd_detector_adversarial.sh tests/test_resume.sh tests/test_cgv_normalize.sh tests/test_cgv_paf_normalize.sh tests/test_cgv_box_filter.sh tests/test_harness_run.sh tests/test_enforcement.sh tests/test_verify_agents.sh; do
  if [[ -f "${t}" ]]; then
    if bash "${t}" >/tmp/verify_$$.log 2>&1; then
      echo -e "  ${GREEN}[PASS]${NC} ${t}"
    else
      echo -e "  ${RED}[FAIL]${NC} ${t}"; sed 's/^/      /' /tmp/verify_$$.log | tail -15; fail=1
    fi
  else
    echo -e "  ${YELLOW}[SKIP]${NC} ${t} (missing)"
  fi
done
rm -f /tmp/verify_$$.log

# ── 2. Pre-flight gate (only meaningful with data present) ─────────────────
echo ""; echo -e "${BOLD}2. Pre-flight gate (init.sh)${NC}"
if [[ -f cactus_v3.0.1.sif && -d genomes ]]; then
  if bash init.sh >/tmp/verify_init_$$.log 2>&1; then
    echo -e "  ${GREEN}[PASS]${NC} init.sh (gate pass generated)"
  else
    echo -e "  ${RED}[FAIL]${NC} init.sh"; tail -15 /tmp/verify_init_$$.log; fail=1
  fi
  rm -f /tmp/verify_init_$$.log
else
  echo -e "  ${YELLOW}[SKIP]${NC} no data present (genomes/ + cactus_v3.0.1.sif) -- harness-only checkout"
fi

# ── 3. Working tree cleanliness ───────────────────────────────────────────
echo ""; echo -e "${BOLD}3. Git working tree${NC}"
if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null; then
  if [[ -z "$(git status --porcelain)" ]]; then
    echo -e "  ${GREEN}[OK]${NC} clean"
  else
    echo -e "  ${YELLOW}[WARN]${NC} uncommitted changes:"; git status --short | sed 's/^/      /'
  fi
else
  echo -e "  ${YELLOW}[SKIP]${NC} not a git repository"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}========================================${NC}"
if (( fail == 0 )); then
  echo -e "${GREEN}${BOLD}VERIFY OK${NC}"; exit 0
else
  echo -e "${RED}${BOLD}VERIFY FAILED${NC}"; exit 1
fi
