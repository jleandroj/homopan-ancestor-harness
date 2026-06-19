#!/usr/bin/env bash
# test_repro_verify_envfix.sh -- regression guard for the repro_verify.sh
# env-var bug (P0.1). The bug: `"${env_pre[@]}" bash ...` puts an expanded
# array in command position; bash does NOT re-parse expanded words as
# assignments, so the first element is run as a command ("command not found").
# The fix is the `env` prefix. This test FAILS if anyone reverts to the bare form.
#
# Fast by default (static + bash-semantics proof). Set HOMOPAN_REPRO_SMOKE=1 to
# also run the full `repro_verify.sh --mock` end-to-end (slower, ~4 min).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/scripts/repro_verify.sh"
pass=0; fail=0
ok()  { echo "  [PASS] $1"; pass=$((pass+1)); }
no()  { echo "  [FAIL] $1"; fail=$((fail+1)); }

echo "repro_verify env-var fix regression"
echo "════════════════════════════════════════"

# 1. bash-semantics proof: the bug class is real, and `env` is the cure.
arr=(FOO=bar)
out_bad=$("${arr[@]}" bash -c 'echo $FOO' 2>&1 || true)
out_fix=$(env "${arr[@]}" bash -c 'echo $FOO' 2>&1 || true)
[[ "${out_bad}" == *"command not found"* ]] && ok "bare array in cmd position fails (bug class confirmed)" \
  || no "expected bare-array form to fail with 'command not found', got: ${out_bad}"
[[ "${out_fix}" == "bar" ]] && ok "env-prefixed array exports the var" \
  || no "expected env-prefixed form to print 'bar', got: ${out_fix}"

# 2. static guard: every run_once invocation must use the env prefix.
n_env=$(grep -c 'env "${env_pre\[@\]}"' "${SRC}" || true)
[[ "${n_env}" -ge 2 ]] && ok "both run_once branches use 'env \"\${env_pre[@]}\"' (found ${n_env})" \
  || no "expected >=2 'env \"\${env_pre[@]}\"' call sites, found ${n_env}"

# 3. static guard: NO bare '"${env_pre[@]}" bash' (would be the regressed bug).
if grep -nE '(^|[^v][^ ])"\$\{env_pre\[@\]\}"[[:space:]]+bash|[^v ]"\$\{env_pre\[@\]\}"[[:space:]]*\\' "${SRC}" \
   | grep -v 'env "${env_pre' >/dev/null; then
  no "found a bare \"\${env_pre[@]}\" not prefixed by env (the regressed bug)"
else
  ok "no bare \"\${env_pre[@]}\" in command position"
fi

# 4. optional end-to-end: --mock exercises run_once -> run_all_test.sh for real
#    (only cactus is stubbed). Would print 'command not found' if the bug returned.
if [[ "${HOMOPAN_REPRO_SMOKE:-0}" == "1" ]]; then
  log=$(mktemp)
  if bash "${SRC}" --mock >"${log}" 2>&1; then
    grep -q 'command not found' "${log}" \
      && no "--mock ran but emitted 'command not found' (bug present)" \
      || ok "--mock end-to-end exit 0, no 'command not found'"
  else
    no "--mock failed (exit $?); see output:"; sed 's/^/      /' "${log}" | tail -15
  fi
  rm -f "${log}"
else
  echo "  [SKIP] --mock end-to-end (set HOMOPAN_REPRO_SMOKE=1 to enable)"
fi

echo ""
echo "  Results: ${pass} passed, ${fail} failed"
(( fail == 0 )) && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
