#!/usr/bin/env bash
# input_integrity_agent.sh <ctx_dir>
# Validates declared inputs BEFORE analysis. Reads <ctx>/inputs.tsv lines:
#   <path>\t<type>     type in: fasta gtf hal maf vcf counts meta
# Checks existence + a cheap format sanity per type. Missing/invalid -> FAIL_VALIDATION.
# No inputs.tsv -> NOT_TESTED (we do not pretend to have validated nothing).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${HERE}/lib_agent.sh"
agent_begin "InputIntegrityAgent"
ctx="${1:?ctx dir}"; spec="${ctx}/inputs.tsv"
[[ -f "${spec}" ]] || { agent_emit NOT_TESTED "no inputs.tsv: nothing declared to validate"; exit $?; }
bad=0; n=0
while IFS=$'\t' read -r path type; do
  [[ -z "${path}" || "${path}" == \#* ]] && continue
  n=$((n+1)); local_ok=1
  # resolve relative to ctx
  [[ "${path}" != /* ]] && path="${ctx}/${path}"
  if [[ ! -s "${path}" ]]; then agent_finding "missing/empty ${type}: ${path}"; bad=1; continue; fi
  case "${type}" in
    fasta) head -c1 "${path}" 2>/dev/null | grep -q '>' || { agent_finding "FASTA does not start with '>': ${path}"; bad=1; local_ok=0; } ;;
    vcf)   head -1 "${path}" 2>/dev/null | grep -q '^##fileformat=VCF' || { agent_finding "VCF missing ##fileformat header: ${path}"; bad=1; local_ok=0; } ;;
    gtf)   grep -qvE '^#' "${path}" 2>/dev/null || { agent_finding "GTF has no records: ${path}"; bad=1; local_ok=0; } ;;
    hal|maf|counts|meta) : ;;  # existence + non-empty is the check here
    *) agent_finding "unknown input type '${type}' for ${path}"; bad=1; local_ok=0 ;;
  esac
  (( local_ok )) && agent_evidence "input" "${type} ok: $(basename "${path}") ($(stat -c%s "${path}" 2>/dev/null) B, sha $(sha256sum "${path}" 2>/dev/null | cut -c1-12))"
done < "${spec}"
(( n == 0 )) && { agent_emit NOT_TESTED "inputs.tsv empty"; exit $?; }
if (( bad )); then agent_emit FAIL_VALIDATION "one or more inputs failed integrity (${n} declared)"; else agent_emit PASS "${n} input(s) present and format-sane"; fi
exit $?
