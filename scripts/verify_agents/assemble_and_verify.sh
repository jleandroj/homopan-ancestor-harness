#!/usr/bin/env bash
# assemble_and_verify.sh <harness_run_dir> [results_dir] [genomes_dir]
# Builds a verification CONTEXT from a finished run's real artifacts, then runs
# the CoordinatorAgent + ReportAgent over it. This is what turns "the pipeline
# executed" into an evidence-gated verdict. Honest by construction: whatever is
# absent (no repro measurement, no claims) becomes NOT_TESTED, never PASS.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
run_dir="${1:?usage: assemble_and_verify.sh <run_dir> [results_dir] [genomes_dir]}"
results="${2:-${ROOT}/results}"
genomes="${3:-${ROOT}/genomes}"
ctx="${run_dir}/verify"; mkdir -p "${ctx}/ancestors"

# Provenance: the run's tamper-evident audit log.
[[ -f "${run_dir}/audit.jsonl" ]] && cp -f "${run_dir}/audit.jsonl" "${ctx}/audit.jsonl"

# Inputs: declare the genome FASTAs (InputIntegrity will format-check + hash).
: > "${ctx}/inputs.tsv"
shopt -s nullglob
for fa in "${genomes}"/*.fa "${genomes}"/*.fasta; do
  printf '%s\tfasta\n' "${fa}" >> "${ctx}/inputs.tsv"
done
[[ -s "${ctx}/inputs.tsv" ]] || rm -f "${ctx}/inputs.tsv"   # none -> NOT_TESTED, not a fake pass

# Ancestors: the real inferred FASTAs + their provenance sidecars.
for fa in "${results}/ancestors"/*.fa; do
  cp -f "${fa}" "${ctx}/ancestors/" 2>/dev/null || true
  [[ -f "${fa}.provenance.json" ]] && cp -f "${fa}.provenance.json" "${ctx}/ancestors/" 2>/dev/null || true
done
rmdir "${ctx}/ancestors" 2>/dev/null || true   # empty -> NOT_TESTED

# Reproducibility: only if a real measurement exists (else NOT_TESTED, honestly).
for rj in "${run_dir}/repro.json" "${ROOT}/qc/repro.json"; do
  [[ -f "${rj}" ]] && { cp -f "${rj}" "${ctx}/repro.json"; break; }
done

# Run the evidence layer.
final="$(bash "${HERE}/coordinator.sh" "${ctx}")"
rc=$?
bash "${HERE}/report_agent.sh" "${ctx}" >/dev/null 2>&1 || true
echo "VERIFICATION: ${final}  (decision: ${ctx}/decision.json · report: ${ctx}/REPORT.md)" >&2
echo "${final}"
exit "${rc}"
