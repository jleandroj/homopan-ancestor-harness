#!/usr/bin/env bash
# test_verify_agents.sh -- the verification layer must enforce "execution != truth":
# good evidence -> PASS_EXPLORATORY/PASS; missing/contradictory evidence -> honest FAIL/UNKNOWN.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CO="${ROOT}/scripts/verify_agents/coordinator.sh"
pass=0; fail=0
ok(){ echo "  [PASS] $1"; pass=$((pass+1)); }
no(){ echo "  [FAIL] $1"; fail=$((fail+1)); }
mkdir -p "${ROOT}/runs"; TMP="$(mktemp -d "${ROOT}/runs/.vtest.XXXXXX")"; trap 'rm -rf "${TMP}"' EXIT
jq="$(command -v jq || echo jq)"
fstat(){ "${jq}" -r '.final_status' < "$1/decision.json"; }

echo "verification agents (execution != truth)"
echo "════════════════════════════════════════"

# ── Scenario A: unbacked claim -> FAIL_EVIDENCE dominates ──────────────────
A="${TMP}/A"; mkdir -p "$A"
printf 'Humans and chimps share an ancestor\tnone\n' > "$A/claims.tsv"
bash "${CO}" "$A" >/dev/null 2>&1
[[ "$(fstat "$A")" == "FAIL_EVIDENCE" ]] && ok "unbacked claim -> FAIL_EVIDENCE" || no "expected FAIL_EVIDENCE got $(fstat "$A")"

# ── Scenario B: AGENT-RECOMPUTED divergence -> FAIL_REPRODUCIBILITY ─────────
B="${TMP}/B"; mkdir -p "$B"
printf 'x\trun:1\n' > "$B/claims.tsv"
printf 'AAA' > "$B/a.hal"; printf 'BBB' > "$B/b.hal"
printf '{"artifact_a":"a.hal","artifact_b":"b.hal","tool":"cactus 9.1.2","seed_supported":false}\n' > "$B/repro.json"
bash "${CO}" "$B" >/dev/null 2>&1
[[ "$(fstat "$B")" == "FAIL_REPRODUCIBILITY" ]] && ok "non-reproducible (agent-recomputed) -> FAIL_REPRODUCIBILITY" || no "expected FAIL_REPRODUCIBILITY got $(fstat "$B")"
# Gap #4 closed: a bare {bit_identical:true} with NO artifacts is NOT trusted.
Bb="${TMP}/Bb"; mkdir -p "$Bb"; printf 'x\trun:1\n' > "$Bb/claims.tsv"
printf '{"bit_identical":true,"tool":"x"}\n' > "$Bb/repro.json"
bash "${CO}" "$Bb" >/dev/null 2>&1
"${jq}" -e '.verdicts[]|select(.agent=="ReproducibilityAgent" and .status=="INSUFFICIENT_EVIDENCE")' < "$Bb/decision.json" >/dev/null 2>&1 \
  && ok "bare {bit_identical:true} (no artifacts) -> INSUFFICIENT_EVIDENCE (not trusted)" || no "bare assertion was TRUSTED (hole open!)"

# ── Scenario C: destructive command -> FAIL_SECURITY dominates everything ──
C="${TMP}/C"; mkdir -p "$C"
printf 'rm -rf genomes/homo_sapiens.fa\n' > "$C/commands.txt"
bash "${CO}" "$C" >/dev/null 2>&1
[[ "$(fstat "$C")" == "FAIL_SECURITY" ]] && ok "destructive cmd -> FAIL_SECURITY" || no "expected FAIL_SECURITY got $(fstat "$C")"

# ── Scenario D: ancestor without provenance -> downgraded, never PASS ──────
D="${TMP}/D"; mkdir -p "$D/ancestors"
printf '>Anc\nACGTACGTACGT\n' > "$D/ancestors/Anc.fa"
bash "${CO}" "$D" >/dev/null 2>&1
fsd="$(fstat "$D")"
[[ "${fsd}" != "PASS" ]] && ok "ancestor w/o provenance is NOT a full PASS (${fsd})" || no "ancestor wrongly PASSed"
"${jq}" -e '.verdicts[]|select(.agent=="AncestorValidationAgent" and .status=="INSUFFICIENT_EVIDENCE")' < "$D/decision.json" >/dev/null 2>&1 \
  && ok "ancestor flagged INSUFFICIENT_EVIDENCE (not observed)" || no "ancestor not flagged"

# ── Scenario E: clean evidence, exploratory repro -> PASS_EXPLORATORY, never silent PASS
E="${TMP}/E"; mkdir -p "$E/ancestors"
printf 'observed divergence X\tinputs.tsv\n' > "$E/claims.tsv"
printf 'meta\tmeta\n' > "$E/inputs.tsv"; echo 'species=homo_sapiens' > "$E/meta"   # a non-empty meta input
printf '%s\n' '{"run_id":"r","type":"action_end","exit":"0","duration_ms":"5","out_bytes":"3","err_bytes":"0"}' > "$E/audit.jsonl"
printf 'SAME' > "$E/a.fa"; printf 'SAME' > "$E/b.fa"   # two identical run artifacts
printf '{"artifact_a":"a.fa","artifact_b":"b.fa","tool":"x"}\n' > "$E/repro.json"
printf '>Anc\nACGTACGT\n' > "$E/ancestors/Anc.fa"
printf '{"determinism":{"reproducible":false}}\n' > "$E/ancestors/Anc.fa.provenance.json"
bash "${CO}" "$E" >/dev/null 2>&1
fse="$(fstat "$E")"
[[ "${fse}" == "PASS_EXPLORATORY" || "${fse}" == "PASS" ]] && ok "clean+equivalent evidence -> ${fse}" || no "expected PASS*/got ${fse}"
# report renders
bash "${ROOT}/scripts/verify_agents/report_agent.sh" "$E" >/dev/null 2>&1 && [[ -f "$E/REPORT.md" ]] \
  && grep -q 'Execution success is NOT scientific truth' "$E/REPORT.md" && ok "report renders with honesty disclaimers" || no "report missing/incomplete"

# ── Scenario F: empty context -> honest UNKNOWN, never PASS ────────────────
F="${TMP}/F"; mkdir -p "$F"
bash "${CO}" "$F" >/dev/null 2>&1
[[ "$(fstat "$F")" == "UNKNOWN" ]] && ok "empty context -> UNKNOWN (not PASS)" || no "expected UNKNOWN got $(fstat "$F")"

# ── Scenario S: semantic FactGuard -- evidence must CONTAIN the claimed token ─
S="${TMP}/S"; mkdir -p "$S"
echo 'p_value=0.9 (not significant)' > "$S/result.txt"
printf 'gene X is significant\tresult.txt\tp_value=0.001\n' > "$S/claims.tsv"
bash "${CO}" "$S" >/dev/null 2>&1
[[ "$(fstat "$S")" == "FAIL_EVIDENCE" ]] && ok "semantic check: evidence lacks claimed token -> FAIL_EVIDENCE" || no "semantic gap (got $(fstat "$S"))"

# ── Scenario G: assemble_and_verify wires a run's artifacts -> decision+report
G="${TMP}/G_run"; mkdir -p "${G}" "${TMP}/Gres/ancestors" "${TMP}/Ggen"
printf '%s\n' '{"run_id":"g","type":"action_end","exit":"0","duration_ms":"5","out_bytes":"3","err_bytes":"0"}' > "${G}/audit.jsonl"
printf '>chr\nACGTACGTACGTACGT\n' > "${TMP}/Ggen/homo_sapiens.fa"
printf '>Anc\nACGTACGTACGT\n' > "${TMP}/Gres/ancestors/Anc.fa"
printf '{"determinism":{"reproducible":false}}\n' > "${TMP}/Gres/ancestors/Anc.fa.provenance.json"
gv="$( bash "${ROOT}/scripts/verify_agents/assemble_and_verify.sh" "${G}" "${TMP}/Gres" "${TMP}/Ggen" 2>/dev/null | tail -1 )"
if [[ -f "${G}/verify/decision.json" && -f "${G}/verify/REPORT.md" ]]; then
  ok "assemble_and_verify builds context -> decision.json + REPORT.md (verdict ${gv})"
  jq -e '.verdicts[]|select(.agent=="ProvenanceAgent")' < "${G}/verify/decision.json" >/dev/null 2>&1 \
    && ok "real audit.jsonl feeds the ProvenanceAgent" || no "provenance not wired"
else
  no "assemble_and_verify produced no decision/report (verdict=${gv})"
fi

echo ""
echo "  Results: ${pass} passed, ${fail} failed"
(( fail == 0 )) && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
