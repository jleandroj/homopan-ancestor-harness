#!/usr/bin/env bash
# test_patch_p1_idempotency.sh -- P1 protected patch: applies apply_protected_p1.sh
# to a THROWAWAY copy of the protected files, verifies the edits land, that a
# second apply is a no-op, and that the results are valid bash.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok(){ echo "  [PASS] $1"; pass=$((pass+1)); }
no(){ echo "  [FAIL] $1"; fail=$((fail+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

echo "P1 protected patch idempotency"
echo "════════════════════════════════════════"

mkdir -p "${TMP}/.claude"
cp "${ROOT}/.claude/gate_check.sh"   "${TMP}/.claude/gate_check.sh"
cp "${ROOT}/.claude/bitacora_log.sh" "${TMP}/.claude/bitacora_log.sh"
cp "${ROOT}/.claude/cmd_detector.sh" "${TMP}/.claude/cmd_detector.sh"

snap(){ cat "${TMP}/.claude/gate_check.sh" "${TMP}/.claude/bitacora_log.sh" | sha256sum | cut -d' ' -f1; }

if bash "${ROOT}/patches/apply_protected_p1.sh" "${TMP}" >/dev/null 2>&1; then
  A="$(snap)"
  bash "${ROOT}/patches/apply_protected_p1.sh" "${TMP}" >/dev/null 2>&1
  B="$(snap)"
  [[ "${A}" == "${B}" ]] && ok "apply 2x = no-op (A==B)" || no "apply NOT idempotent"
else
  no "apply_protected_p1.sh failed on the copy"
fi

# P1.1: bitacora now logs Read
grep -qE 'Write\|Edit\|NotebookEdit\|Bash\|Read' "${TMP}/.claude/bitacora_log.sh" \
  && ok "bitacora_log.sh logs Read" || no "Read not added to bitacora log case"
grep -qE '"Edit" \|\| .* == "Read"' "${TMP}/.claude/bitacora_log.sh" \
  && ok "bitacora_log.sh hashes Read files" || no "Read not added to hash case"

# P1.2: gate has the realpath clinical gate covering file tools
grep -q 'realpath gate' "${TMP}/.claude/gate_check.sh" \
  && ok "gate_check.sh has realpath clinical-data deny" || no "clinical realpath block missing"
grep -qE 'Read\|Edit\|Write\|NotebookEdit' "${TMP}/.claude/gate_check.sh" \
  && ok "clinical deny covers Read/Edit/Write/NotebookEdit" || no "file-tool coverage missing"

# results are valid bash
bash -n "${TMP}/.claude/gate_check.sh"   && ok "gate_check.sh valid bash"   || no "gate_check.sh syntax error"
bash -n "${TMP}/.claude/bitacora_log.sh" && ok "bitacora_log.sh valid bash" || no "bitacora_log.sh syntax error"

echo ""
echo "  Results: ${pass} passed, ${fail} failed"
(( fail == 0 )) && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
