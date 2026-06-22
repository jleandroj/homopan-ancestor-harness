#!/usr/bin/env bash
# test_enforcement.sh -- containment + audit integrity (assume bad-faith agent).
# Verifies: (a) inside the sandbox the agent cannot read host secrets, (b) the
# audit hash-chain detects tampering. Sandbox tests skip cleanly if bwrap/userns
# is unavailable (CI installs bubblewrap).
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/he.XXXXXX")"; trap 'rm -rf "${TMP}"' EXIT
AUD="${TMP}/audit.jsonl"
fail=0; ck(){ [[ "$1" == "$2" ]] && echo "  [PASS] $3" || { echo "  [FAIL] $3 (got '$1' want '$2')"; fail=1; }; }

sandbox_ok=1
if ! bwrap --unshare-user --unshare-net --ro-bind /usr /usr --tmpfs /tmp true >/dev/null 2>&1; then
  echo "  [SKIP] bwrap/userns no disponible -> sólo pruebo audit integrity"; sandbox_ok=0
fi

if (( sandbox_ok )); then
  # fake secret in a fake HOME; sandbox must hide the real $HOME
  out="$(HARNESS_AUDIT_LOG="${AUD}" HARNESS_SANDBOX=1 bash "${SRC}/scripts/harness_run.sh" --label sec \
        -- bash -c 'ls -la ~/.ssh 2>&1; cat ~/.aws/credentials 2>&1' 2>/dev/null || true)"
  grep -qiE 'no such file|cannot access|not found|No existe' <<<"$out"; ck "$?" "0" "sandbox hides host \$HOME/.ssh/.aws"

  # inside sandbox, default no-net: a network attempt should fail
  netout="$(HARNESS_AUDIT_LOG="${AUD}" HARNESS_SANDBOX=1 bash "${SRC}/scripts/harness_run.sh" --label net \
        -- bash -c 'getent hosts api.github.com 2>&1; echo rc=$?' 2>/dev/null || true)"
  # (best-effort: no-net means resolution/connect fails; we just assert it ran + logged)
  grep -q '"label":"net"' "${AUD}"; ck "$?" "0" "network-attempt run logged"
fi

# audit hash-chain: intact passes, tampering detected
HARNESS_AUDIT_LOG="${AUD}" HARNESS_SANDBOX=0 bash "${SRC}/scripts/harness_run.sh" --label a -- echo 1 >/dev/null 2>&1
HARNESS_AUDIT_LOG="${AUD}" HARNESS_SANDBOX=0 bash "${SRC}/scripts/harness_run.sh" --label b -- echo 2 >/dev/null 2>&1
bash "${SRC}/scripts/haudit_verify.sh" "${AUD}" >/dev/null 2>&1; ck "$?" "0" "intact audit chain verifies"
# tamper: edit a middle line
sed -i '2s/.*/{"run_id":"X","tampered":true}/' "${AUD}" 2>/dev/null || true
bash "${SRC}/scripts/haudit_verify.sh" "${AUD}" >/dev/null 2>&1; rc=$?
ck "$( ((rc!=0)) && echo tamper-detected || echo missed )" "tamper-detected" "tampering breaks the hash chain"

echo ""; (( fail==0 )) && echo "test_enforcement: ALL PASS" || { echo "test_enforcement: FAILED"; exit 1; }
