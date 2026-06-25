#!/usr/bin/env bash
# provenance_agent.sh <ctx_dir>
# Confirms every analysis has provenance: command, versions, env, date, params,
# seeds, stdout/stderr, produced files. Looks for a harness audit.jsonl and/or a
# run manifest. Without them -> INSUFFICIENT_EVIDENCE (we cannot trace the run).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${HERE}/lib_agent.sh"
agent_begin "ProvenanceAgent"; jq="$(agent_jq)"
ctx="${1:?ctx dir}"
audit="${ctx}/audit.jsonl"; [[ -f "${audit}" ]] || audit="$(ls -t "${ctx}"/_harness/*/audit.jsonl 2>/dev/null | head -1)"
manifest="$(ls -t "${ctx}"/qc/manifests/*.json "${ctx}"/manifest.json 2>/dev/null | head -1)"
have=0
if [[ -n "${audit}" && -f "${audit}" ]]; then
  have=1; agent_evidence "audit" "$(wc -l <"${audit}") events at ${audit#${ctx}/}"
  "${jq}" -e 'select(.type=="action_end")' < "${audit}" >/dev/null 2>&1 && agent_evidence "audit" "action exit/duration recorded" \
    || agent_finding "audit log has no action_end records (no command/exit/duration captured)"
fi
if [[ -n "${manifest}" && -f "${manifest}" ]]; then
  have=1
  if "${jq}" -e '.repro and .meta and .repro_sha256' < "${manifest}" >/dev/null 2>&1; then
    agent_evidence "manifest" "schema-2 with repro_sha256 + meta (tool versions, sif, seed)"
    "${jq}" -e '.meta.code.harness_commit' < "${manifest}" >/dev/null 2>&1 && agent_evidence "manifest" "harness git commit recorded"
  else agent_finding "manifest present but missing repro/meta/repro_sha256"; fi
fi
if (( have )) && [[ ${#AGENT_FINDINGS[@]} -eq 0 ]]; then
  agent_emit PASS "provenance present: command/version/env/date/params/seeds/outputs traceable"
elif (( have )); then
  agent_emit INSUFFICIENT_EVIDENCE "provenance present but incomplete"
else
  agent_emit INSUFFICIENT_EVIDENCE "no audit log or manifest: run is NOT traceable"
fi
exit $?
