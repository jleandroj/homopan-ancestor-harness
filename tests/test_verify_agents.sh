#!/usr/bin/env bash
# Tests the scientific verification layer enforces "execution != truth":
#   1. FactGuard FAILs a claim with no evidence.
#   2. FactGuard PASSes a claim whose evidence file exists.
#   3. Literature flags a novelty claim with no literature pointer.
#   4. Coordinator blocks biological conclusions when the backbone is not PASS.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="${ROOT}/agents"
fail=0; pass=0
ok(){ echo "  ok: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# capable jq (snap jq cannot open .harness/ files)
jqr(){ local j; for j in "${HOME}/miniconda3/envs/homopan_ancestor/bin/jq" /usr/bin/jq; do
         [ -x "$j" ] && { "$j" "$@"; return; }; done
       j="$(command -v jq)"; [[ -n "$j" && "$j" != /snap/* ]] && "$j" "$@"; }

# ---- 1 & 2 & 3: FactGuard / Literature on a crafted claims file -------------
CLAIMS="${TMP}/claims.tsv"
printf 'A claim with no evidence\tnone\t\n'                 >  "$CLAIMS"
printf 'A claim backed by a real file\tfile\tagents/lib_verdict.sh\n' >> "$CLAIMS"
printf 'The first ever such finding\tnone\t\n'             >> "$CLAIMS"

VR="${TMP}/vrun"; mkdir -p "$VR"
CLAIMS="$CLAIMS" VERIFY_RUN_DIR="$VR" bash "$A/fact_guard.sh" >/dev/null 2>&1
FG="${VR}/verdicts/FactGuardAgent.verdict.json"
[[ -s "$FG" ]] && ok "fact_guard wrote a verdict" || no "fact_guard verdict missing"
if jqr -e '.checks[] | select(.status=="FAIL_EVIDENCE")' "$FG" >/dev/null 2>&1; then
  ok "fact_guard FAIL_EVIDENCE on no-evidence claim"
else no "fact_guard did not flag the no-evidence claim"; fi
if jqr -e '.checks[] | select(.status=="PASS")' "$FG" >/dev/null 2>&1; then
  ok "fact_guard PASS on real-file claim"
else no "fact_guard did not pass the real-file claim"; fi

CLAIMS="$CLAIMS" VERIFY_RUN_DIR="$VR" bash "$A/literature.sh" >/dev/null 2>&1
LT="${VR}/verdicts/LiteratureAgent.verdict.json"
if jqr -e '.checks[] | select(.status=="UNKNOWN")' "$LT" >/dev/null 2>&1; then
  ok "literature flags unsupported novelty as UNKNOWN"
else no "literature did not flag unsupported novelty"; fi

# ---- 4: coordinator blocks bio when backbone not PASS ----------------------
# (in a clean checkout the audit log / manifests are absent, so the backbone is
#  INSUFFICIENT_EVIDENCE -> biological_conclusions_allowed must be false)
CLAIMS="$CLAIMS" bash "$A/coordinator.sh" >/dev/null 2>&1
DEC="$(ls -1dt "${ROOT}"/.harness/verify/*/decision.json 2>/dev/null | head -1)"
if [[ -s "$DEC" ]]; then
  ok "coordinator wrote decision.json"
  allowed="$(jqr -r '.biological_conclusions_allowed' "$DEC")"
  [[ "$allowed" == "false" ]] && ok "bio conclusions BLOCKED without evidence backbone" \
                              || no "bio conclusions allowed despite weak backbone ($allowed)"
  [[ -s "$(dirname "$DEC")/REPORT.md" ]] && ok "report rendered" || no "REPORT.md missing"
else no "coordinator produced no decision.json"; fi

echo "---- verify agents: ${pass} ok, ${fail} fail ----"
exit $(( fail > 0 ? 1 : 0 ))
