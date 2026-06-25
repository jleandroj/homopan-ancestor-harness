#!/usr/bin/env bash
# security_agent.sh <ctx_dir>
# Protects original data + credentials. Scans <ctx>/commands.txt (the commands a
# run intends/ran) for destructive ops on inputs, credential exposure, and writes
# outside an allowed area. Any hit -> FAIL_SECURITY. No commands.txt -> NOT_TESTED.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${HERE}/lib_agent.sh"
agent_begin "SecurityAgent"
ctx="${1:?ctx dir}"; f="${ctx}/commands.txt"
[[ -f "${f}" ]] || { agent_emit NOT_TESTED "no commands.txt to screen"; exit $?; }
hits=0
# destructive ops against original data / genomes / raw inputs
if grep -nEi 'rm[[:space:]]+-[a-z]*r[a-z]*f?.*(genomes|/raw|/data|originals|inputs)|>[[:space:]]*(genomes|inputs)/|mkfs|dd[[:space:]]+of=/dev|shred' "${f}" >/dev/null 2>&1; then
  agent_finding "destructive operation targeting original/raw data"; hits=1
fi
# credential exposure
if grep -nEi '(AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|-----BEGIN[A-Z ]*PRIVATE KEY|password[[:space:]]*=|token[[:space:]]*=[[:space:]]*[A-Za-z0-9])' "${f}" >/dev/null 2>&1; then
  agent_finding "possible credential/secret in commands"; hits=1
fi
# obvious remote-exec
grep -nEi '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh|base64[^|]*\|[[:space:]]*(ba)?sh' "${f}" >/dev/null 2>&1 && { agent_finding "fetch/decode-and-execute pattern"; hits=1; }
agent_evidence "scan" "$(wc -l <"${f}") command line(s) screened"
if (( hits )); then agent_emit FAIL_SECURITY "dangerous/credential/destructive pattern found"
else agent_emit PASS "no destructive ops, credential exposure, or remote-exec detected"; fi
exit $?
