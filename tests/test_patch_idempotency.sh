#!/usr/bin/env bash
# test_patch_idempotency.sh -- P0.4 regression: the protected-file patch flow is
# IDEMPOTENT. The old apply_protected_p1_p3.sh re-inserted blocks on every run
# (skip guard failed when `new` contained `old`) -> triplication. This test runs
# the flow against a THROWAWAY copy of the tree (never the real protected files)
# and asserts a second apply changes nothing.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok(){ echo "  [PASS] $1"; pass=$((pass+1)); }
no(){ echo "  [FAIL] $1"; fail=$((fail+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

echo "protected-file patch idempotency (P0.4)"
echo "════════════════════════════════════════"

# Mirror only the files the two scripts touch.
mkdir -p "${TMP}/.claude" "${TMP}/scripts/net_wrappers"
cp "${ROOT}/init.sh"                          "${TMP}/init.sh"
cp "${ROOT}/.claude/gate_check.sh"            "${TMP}/.claude/gate_check.sh"
cp "${ROOT}/.claude/bitacora_log.sh"          "${TMP}/.claude/bitacora_log.sh"
cp "${ROOT}/scripts/net_wrappers/_guard.sh"   "${TMP}/scripts/net_wrappers/_guard.sh"

snap(){ cat "${TMP}/init.sh" "${TMP}/.claude/gate_check.sh" \
            "${TMP}/.claude/bitacora_log.sh" "${TMP}/scripts/net_wrappers/_guard.sh" \
        | sha256sum | cut -d' ' -f1; }

# 0. Collapse any triplication on the copy -> canonical single-applied state.
python3 "${ROOT}/patches/cleanup_triplication.py" "${TMP}" >/dev/null 2>&1
C="$(snap)"
# cleanup must itself be idempotent
python3 "${ROOT}/patches/cleanup_triplication.py" "${TMP}" >/dev/null 2>&1
[[ "$(snap)" == "${C}" ]] && ok "cleanup_triplication.py idempotent (2nd run no-op)" \
  || no "cleanup_triplication.py NOT idempotent"

# 1. Apply once, then again; the second apply must be a no-op (diff empty).
if bash "${ROOT}/patches/apply_protected_p1_p3.sh" "${TMP}" >/dev/null 2>&1; then
  A="$(snap)"
  bash "${ROOT}/patches/apply_protected_p1_p3.sh" "${TMP}" >/dev/null 2>&1
  B="$(snap)"
  [[ "${A}" == "${B}" ]] && ok "apply 2x = no-op (A==B, diff empty)" \
    || no "apply NOT idempotent: A=${A:0:12} B=${B:0:12}"
  # 2. Apply on an already-applied clean surface must not mutate it (mask fix).
  [[ "${A}" == "${C}" ]] && ok "apply is a no-op on already-applied surface (no re-insert)" \
    || no "apply mutated an already-applied surface (the triplication bug): C=${C:0:12} A=${A:0:12}"
else
  no "apply_protected_p1_p3.sh failed on the copy"
fi

# 3. No block ended up duplicated after the whole flow.
g=$(grep -cF 'source "${SCRIPT_DIR}/cmd_detector.sh"' "${TMP}/.claude/gate_check.sh")
w=$(grep -cF 'max-redirect=0' "${TMP}/scripts/net_wrappers/_guard.sh")
[[ "${g}" == "1" && "${w}" == "1" ]] && ok "no residual duplication (gate source=${g}, guard maxredir=${w})" \
  || no "residual duplication: gate source=${g}, guard maxredir=${w}"

echo ""
echo "  Results: ${pass} passed, ${fail} failed"
(( fail == 0 )) && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
