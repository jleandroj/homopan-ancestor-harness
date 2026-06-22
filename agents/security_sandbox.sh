#!/usr/bin/env bash
# SecuritySandboxAgent -- verifies the containment/integrity boundary is intact:
# gate pass present, audit hash-chain not tampered, sandbox available, protected
# files not writable by the agent. Reuses the existing gate + haudit_verify.
source "$(dirname "${BASH_SOURCE[0]}")/lib_verdict.sh"
verdict_init "SecuritySandboxAgent"

GP="${ROOT}/.claude/.gate_pass"
[[ -f "${GP}" ]] && check gate_pass PASS "${GP}" "content-hash gate pass present" \
                 || check gate_pass INSUFFICIENT_EVIDENCE "" "no gate pass; run bash init.sh"

if [[ -x "${ROOT}/scripts/haudit_verify.sh" ]]; then
  if bash "${ROOT}/scripts/haudit_verify.sh" >/dev/null 2>&1; then
    check audit_chain PASS "~/.harness_audit.jsonl" "append-only hash chain intact"
  else
    check audit_chain FAIL_SECURITY "~/.harness_audit.jsonl" "audit hash chain BROKEN (tamper) or absent"
  fi
else
  check audit_chain NOT_TESTED "" "haudit_verify.sh not present"
fi

if command -v bwrap >/dev/null 2>&1 && bwrap --unshare-user --ro-bind /usr /usr --tmpfs /tmp true >/dev/null 2>&1; then
  check sandbox PASS "bwrap" "bubblewrap available and can create namespaces"
else
  check sandbox INSUFFICIENT_EVIDENCE "" "bwrap unavailable or userns disabled -> real containment not guaranteed"
fi

# protected files must not be agent-writable (deny list present in settings)
if grep -q 'gate_check.sh' "${ROOT}/.claude/settings.json" 2>/dev/null; then
  check protected_files PASS ".claude/settings.json" "contract files in permissions.deny"
else
  check protected_files INSUFFICIENT_EVIDENCE "" "settings.json deny list not found"
fi
verdict_emit "security boundary check"
