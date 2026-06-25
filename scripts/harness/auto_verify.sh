#!/usr/bin/env bash
# auto_verify.sh -- Stop-hook entrypoint: runs the honesty checks AUTOMATICALLY
# after every agent turn, so the user never has to run them by hand. It reads the
# hook JSON on stdin (ignored if absent), is FAIL-OPEN (never blocks the session),
# and prints a concise summary so issues surface in the conversation each turn.
#
# Wire it as a Stop hook in .claude/settings.json (see scripts/harness/HOOKS.md).
set -uo pipefail
cat >/dev/null 2>&1 || true   # drain hook stdin if any
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SELF}/../.." && pwd)"               # where the scripts live (real repo)
ROOT="${HARNESS_VERIFY_ROOT:-${REPO}}"            # where the STATE lives (overridable for tests)
VA="${REPO}/scripts/verify_agents"
jqx() { command -v jq >/dev/null 2>&1 && jq "$@" || cat; }
warns=()

# 1. Cross-run cherry-pick smell (same inputs analysed multiple times).
if [[ -f "${ROOT}/runs/_ledger.jsonl" ]]; then
  bash "${VA}/ledger_audit.sh" "${ROOT}/runs/_ledger.jsonl" >/dev/null 2>&1 \
    || warns+=("cherry-pick smell: same inputs were run multiple times (see ledger_audit.sh)")
fi

# 2. Any DECLARED claims must be backed (incl. the semantic token check).
if [[ -f "${ROOT}/claims.tsv" ]]; then
  st="$(bash "${VA}/fact_guard_agent.sh" "${ROOT}" 2>/dev/null | tail -1 | jqx -r '.status' 2>/dev/null)"
  case "${st}" in FAIL_*|INSUFFICIENT_EVIDENCE) warns+=("claims.tsv: FactGuard=${st} (a stated claim is unbacked or unsupported)") ;; esac
fi

# 3. Integrity of the most recent supervised run's audit log.
last_run="$(ls -td "${ROOT}"/runs/_harness/*/ 2>/dev/null | head -1)"
if [[ -n "${last_run}" && -f "${last_run%/}/audit.jsonl" ]]; then
  bash "${REPO}/scripts/harness/harness.sh" verify "${last_run%/}/audit.jsonl" >/dev/null 2>&1 \
    || warns+=("audit-log integrity FAILED for run ${last_run%/}")
fi

if (( ${#warns[@]} )); then
  echo "🔎 AUTO-VERIFY (harness): ${#warns[@]} issue(s) this turn —"
  printf '   ⚠ %s\n' "${warns[@]}"
  echo "   Tip: reconcile any number I stated against the file with scripts/verify_agents/reconcile.sh <file> <stated> [pattern]"
else
  echo "🔎 AUTO-VERIFY (harness): no integrity / evidence / cherry-pick issues detected this turn."
fi
exit 0   # fail-open: the verifier never blocks your session
