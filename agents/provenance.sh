#!/usr/bin/env bash
# ProvenanceAgent -- every result must carry provenance: command, versions, env,
# date, params, seeds, output hashes. Reuses the harness audit log + manifests.
source "$(dirname "${BASH_SOURCE[0]}")/lib_verdict.sh"
verdict_init "ProvenanceAgent"

AUDIT="${HARNESS_AUDIT_LOG:-${HOME}/.harness_audit.jsonl}"
if [[ -s "${AUDIT}" ]]; then
  n=$(grep -c '"event":"end"' "${AUDIT}" 2>/dev/null || echo 0)
  check audit_log PASS "${AUDIT}" "${n} recorded actions (cmd/exit/duration/output-hash)"
else
  check audit_log INSUFFICIENT_EVIDENCE "" "no harness audit log; run work via scripts/harness_run.sh"
fi

# per-run manifests (toolchain versions + input/output sha256 + repro_sha256)
man=$(ls -1t "${ROOT}"/qc/manifests/*.json "${ROOT}"/runs/*/qc/manifests/*.json 2>/dev/null | head -1)
if [[ -n "${man}" && -s "${man}" ]]; then
  if grep -q 'repro_sha256' "${man}" 2>/dev/null; then
    check manifest PASS "${man}" "schema-2 manifest with repro_sha256 + tool versions"
  else
    check manifest INSUFFICIENT_EVIDENCE "${man}" "manifest present but no repro_sha256"
  fi
else
  check manifest NOT_TESTED "" "no run manifest (no pipeline run recorded)"
fi

# CGV pairwise provenance: PAF (raw evidence) retained?
npaf=$(ls -1 "${ROOT}"/results/cgv/pairs/*.paf "${ROOT}"/results/cgv/*/blocks/*.paf 2>/dev/null | wc -l)
(( npaf > 0 )) && check raw_alignments PASS "results/cgv/.../*.paf" "${npaf} raw alignment files retained as evidence" \
              || check raw_alignments NOT_TESTED "" "no raw PAF alignments present"
verdict_emit "provenance / audit trail"
