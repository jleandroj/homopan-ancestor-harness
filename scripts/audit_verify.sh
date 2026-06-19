#!/usr/bin/env bash
# audit_verify.sh -- verify the audit trail's integrity & local<->external
# consistency (#8), and help make the external log truly append-only.
#
# The PostToolUse logger (.claude/bitacora_log.sh) writes every mutating tool
# call to TWO places:
#   - logs/bitacora.jsonl        (in-repo, size-rotated, can be wiped)
#   - $HOMOPAN_AUDIT_LOG          (external, default ~/.homopan_audit.jsonl)
# The external log is the tamper-evident copy: it lives outside the repo so it
# survives a repo wipe, and an admin can make it APPEND-ONLY with `chattr +a`
# so even root-in-repo cannot rewrite history without an explicit attribute flip.
#
# This script checks:
#   1. both logs are well-formed JSONL,
#   2. every line currently in the in-repo log (incl. rotations) is present in
#      the external log  (external must be a superset -> no lost/edited audit),
#   3. the external log is actually append-only (lsattr), and prints the exact
#      command to enable it if not.
# Exit: 0 = consistent, 1 = drift/corruption detected, 2 = setup problem.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"
LOCAL="${PROJECT_ROOT}/logs/bitacora.jsonl"
AUDIT_LOG="${HOMOPAN_AUDIT_LOG:-${HOME}/.homopan_audit.jsonl}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok(){ echo -e "  ${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "  ${YELLOW}[WARN]${NC} $*"; }
err(){ echo -e "  ${RED}[FAIL]${NC} $*"; }

echo -e "${BOLD}Audit trail verification${NC}"
echo -e "${BOLD}────────────────────────────────────────${NC}"
echo "  in-repo : ${LOCAL}"
echo "  external: ${AUDIT_LOG}"

rc=0

# ── 0. External log must exist ────────────────────────────────────────────
if [[ ! -f "${AUDIT_LOG}" ]]; then
  warn "external audit log not found yet (no mutating tool has run, or path differs)."
  warn "It will be created on the first Write/Edit/Bash. Nothing to verify."
  exit 0
fi

# ── 1. Well-formed JSONL ──────────────────────────────────────────────────
validate_jsonl() {   # <file> <label>
  local f="$1" label="$2" bad=0 ln
  [[ -f "$f" ]] || { ok "${label}: absent (skipped)"; return 0; }
  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r ln; do [[ -z "$ln" ]] && continue; jq -e . >/dev/null 2>&1 <<<"$ln" || bad=$((bad+1)); done < "$f"
  else
    while IFS= read -r ln; do [[ -z "$ln" ]] && continue; [[ "$ln" == \{*\} ]] || bad=$((bad+1)); done < "$f"
  fi
  if (( bad == 0 )); then ok "${label}: well-formed JSONL ($(wc -l < "$f" | tr -d ' ') lines)"; else err "${label}: ${bad} malformed line(s)"; rc=1; fi
}
echo ""; echo -e "${BOLD}1. JSONL validity${NC}"
validate_jsonl "${AUDIT_LOG}" "external"
validate_jsonl "${LOCAL}" "in-repo (current)"

# ── 2. External is a superset of every in-repo line (incl. rotations) ─────
echo ""; echo -e "${BOLD}2. local ⊆ external (no lost/edited audit entries)${NC}"
TMP_LOCAL="$(mktemp)"; trap 'rm -f "${TMP_LOCAL}"' EXIT
: > "${TMP_LOCAL}"
shopt -s nullglob
for f in "${LOCAL}" "${LOCAL}".*; do [[ -f "$f" ]] && cat "$f" >> "${TMP_LOCAL}"; done
shopt -u nullglob
if [[ -s "${TMP_LOCAL}" ]]; then
  # Every non-empty in-repo line must appear verbatim in the external log.
  missing=0
  while IFS= read -r ln; do
    [[ -z "$ln" ]] && continue
    grep -qxF -- "$ln" "${AUDIT_LOG}" || missing=$((missing+1))
  done < <(sort -u "${TMP_LOCAL}")
  if (( missing == 0 )); then
    ok "all in-repo audit lines are present in the external log"
  else
    err "${missing} in-repo audit line(s) NOT found in external log (drift/tampering or external truncated)"
    rc=1
  fi
  ext_n=$(wc -l < "${AUDIT_LOG}" | tr -d ' '); loc_n=$(sort -u "${TMP_LOCAL}" | grep -c . || true)
  echo "      external lines: ${ext_n} ; unique in-repo lines: ${loc_n}"
else
  ok "no in-repo audit lines to cross-check yet"
fi

# ── 3. Append-only attribute on the external log ──────────────────────────
echo ""; echo -e "${BOLD}3. Append-only protection (chattr +a)${NC}"
if command -v lsattr >/dev/null 2>&1; then
  attrs=$(lsattr "${AUDIT_LOG}" 2>/dev/null | awk '{print $1}')
  if [[ "${attrs}" == *a* ]]; then
    ok "external log is append-only (chattr +a set): history cannot be rewritten in place"
  else
    warn "external log is NOT append-only. To make the audit trail tamper-evident, run:"
    echo  "        sudo chattr +a '${AUDIT_LOG}'"
    warn "(append-only requires a supporting filesystem (ext4/xfs) and CAP_LINUX_IMMUTABLE.)"
  fi
else
  warn "lsattr not available; cannot check append-only status (non-Linux or e2fsprogs missing)."
fi

echo ""
echo -e "${BOLD}────────────────────────────────────────${NC}"
if (( rc == 0 )); then
  echo -e "${GREEN}${BOLD}AUDIT CONSISTENT${NC}"
else
  echo -e "${RED}${BOLD}AUDIT DRIFT/CORRUPTION DETECTED${NC}"
fi
exit "${rc}"
