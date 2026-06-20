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

# P1.1: bitacora logs Read only when opt-in (no noise by default)
grep -q 'HOMOPAN_LOG_READS' "${TMP}/.claude/bitacora_log.sh" \
  && ok "bitacora_log.sh Read logging is opt-in (HOMOPAN_LOG_READS)" || no "opt-in Read logging missing"
grep -qE '"Edit" \|\| .* == "Read"' "${TMP}/.claude/bitacora_log.sh" \
  && ok "bitacora_log.sh hashes Read files when logged" || no "Read not added to hash case"

# P1.2: gate has the realpath clinical gate + records denied attempts
grep -q 'realpath gate' "${TMP}/.claude/gate_check.sh" \
  && ok "gate_check.sh has realpath clinical-data deny" || no "clinical realpath block missing"
grep -qE 'Read\|Edit\|Write\|NotebookEdit' "${TMP}/.claude/gate_check.sh" \
  && ok "clinical deny covers Read/Edit/Write/NotebookEdit" || no "file-tool coverage missing"
grep -q 'DENY_CLINICAL' "${TMP}/.claude/gate_check.sh" \
  && ok "clinical deny is recorded to the audit log" || no "denied clinical attempt not audited"

# results are valid bash
bash -n "${TMP}/.claude/gate_check.sh"   && ok "gate_check.sh valid bash"   || no "gate_check.sh syntax error"
bash -n "${TMP}/.claude/bitacora_log.sh" && ok "bitacora_log.sh valid bash" || no "bitacora_log.sh syntax error"

# P2.2: jq hard-required guard present + runtime logging still produces valid JSONL
grep -q 'jq is hard-required' "${TMP}/.claude/bitacora_log.sh" \
  && ok "bitacora has jq-hard-required guard (P2.2)" || no "P2.2 jq-hard guard missing"
if command -v jq >/dev/null 2>&1; then
  echo '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"session_id":"s1","cwd":"/x","tool_response":{}}' \
    | HOMOPAN_AUDIT_LOG="${TMP}/audit.jsonl" bash "${TMP}/.claude/bitacora_log.sh" >/dev/null 2>&1
  ln="$(tail -1 "${TMP}/logs/bitacora.jsonl" 2>/dev/null)"
  echo "${ln}" | jq -e '.tool=="Bash" and .detail=="echo hi"' >/dev/null 2>&1 \
    && ok "patched bitacora logs valid JSONL at runtime" || no "bitacora runtime broken: ${ln}"
else
  echo "  [SKIP] runtime JSONL check (no host jq)"
fi

echo ""
echo "  Results: ${pass} passed, ${fail} failed"
(( fail == 0 )) && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
