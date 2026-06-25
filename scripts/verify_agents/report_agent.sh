#!/usr/bin/env bash
# report_agent.sh <ctx_dir>
# Renders <ctx>/decision.json (produced by the coordinator) into a human report
# with explicit confidence levels and honest disclaimers. Never upgrades a status.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${HERE}/lib_agent.sh"
jq="$(agent_jq)"
ctx="${1:?ctx dir}"; d="${ctx}/decision.json"
[[ -f "${d}" ]] || { echo "report_agent: no decision.json (run coordinator first)" >&2; exit 2; }
conf() { case "$1" in
  PASS) echo "HIGH (reproducible + evidence-backed)";;
  PASS_EXPLORATORY) echo "LOW/EXPLORATORY (not confirmatory)";;
  FAIL_REPRODUCIBILITY) echo "NONE (not reproducible)";;
  FAIL_EVIDENCE) echo "NONE (unbacked claim)";;
  FAIL_SECURITY) echo "BLOCKED (security)";;
  FAIL_TECHNICAL) echo "NONE (failed validation)";;
  *) echo "UNKNOWN";; esac; }
out="${ctx}/REPORT.md"
{
  fs="$("${jq}" -r '.final_status' < "${d}")"
  echo "# Verification report"
  echo
  echo "- **Final status: ${fs}**  — confidence: $(conf "${fs}")"
  echo "- decided_at: $("${jq}" -r '.decided_at' < "${d}")"
  echo "- mandatory gates: FactGuard=$("${jq}" -r '.mandatory_gates.FactGuard' < "${d}"), Provenance=$("${jq}" -r '.mandatory_gates.Provenance' < "${d}"), Reproducibility=$("${jq}" -r '.mandatory_gates.Reproducibility' < "${d}")"
  echo
  echo "## Per-agent verdicts"
  echo "| agent | status | summary |"
  echo "|---|---|---|"
  "${jq}" -r '.verdicts[] | "| \(.agent) | \(.status) | \(.summary) |"' < "${d}"
  echo
  echo "## Findings (why not higher)"
  "${jq}" -r '.reasons[]? | "- \(.)"' < "${d}"
  echo
  echo "## Honesty disclaimers"
  echo "- Execution success is NOT scientific truth."
  echo "- Reconstructed ancestors are INFERRED, never observed genomes."
  echo "- A non-reproducible result is NOT biological evidence."
  echo "- Anything marked NOT_TESTED / UNKNOWN / INSUFFICIENT_EVIDENCE was not established by this run."
  echo
  echo "## Residual lie-vectors this verdict does NOT cover (read before trusting)"
  echo "The harness checks structure, evidence-linkage and reproducibility — NOT scientific intent. It can still be wrong if:"
  echo "1. **Wrong-but-valid config.** A flipped contrast (numerator/denominator), wrong FDR, or wrong gene_id_type produces a *valid* result that passes every check but is scientifically false. Garbage-in-valid → garbage-out-valid. *(NOT auto-detectable — needs human/design review.)*"
  echo "2. **Prose vs. files.** Any number stated in chat is unverified unless reconciled against the on-disk file. Use \`scripts/verify_agents/reconcile.sh\` to compare a stated value to the actual result. *(The harness trusts files, never prose.)*"
  echo "3. **Cherry-picking across runs.** A single run is honest; selecting one favorable run out of many is a separate decision. See the run ledger (\`runs/_ledger.jsonl\`) to check whether sibling runs were hidden."
  echo "4. **AI reasoning is not reproducible.** Prompts/model/why-this-config are recorded only as available (\`meta.llm\`, decisions); the rationale itself cannot be replayed or proven. *(Irreducible.)*"
  echo "5. **The harness does not verify its own prose.** Narrative claims (including in reports) are not auto-checked; only the structured verdicts above are. Trust the table, not the sentences."
} > "${out}"
echo "${out}"
