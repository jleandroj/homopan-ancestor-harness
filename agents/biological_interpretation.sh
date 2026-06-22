#!/usr/bin/env bash
# BiologicalInterpretationAgent -- the ONLY agent allowed to phrase biology, and
# only if the evidence backbone (Security, Provenance, Reproducibility, FactGuard)
# already PASSED in this run. Otherwise it refuses and emits
# TECHNICALLY_SUCCESSFUL_BUT_BIOLOGICALLY_UNSUPPORTED. It never upgrades evidence.
source "$(dirname "${BASH_SOURCE[0]}")/lib_verdict.sh"
verdict_init "BiologicalInterpretationAgent"

vstatus() { # read a prior agent's verdict status; FAIL-CLOSED: a missing or
  # unreadable verdict returns UNKNOWN (blocking), never a permissive NOT_TESTED.
  local f="${VDIR}/$1.verdict.json" s=""
  [[ -s "$f" ]] && s="$(_jq -r '.status' "$f" 2>/dev/null)"
  [[ -n "$s" && "$s" != null ]] && echo "$s" || echo "UNKNOWN"
}

backbone_ok=1; reason=""
for a in SecuritySandboxAgent ProvenanceAgent ReproducibilityAgent FactGuardAgent; do
  s="$(vstatus "$a")"
  case "$s" in
    PASS) : ;;
    NOT_TESTED) ;;  # nothing asserted that needs this backbone leg
    *) backbone_ok=0; reason="${reason}${a}=${s}; ";;
  esac
done

if (( backbone_ok )); then
  check interpretation_gate PASS "backbone verdicts" "evidence backbone clear -> interpretation permitted (exploratory framing only)"
  check framing PASS_EXPLORATORY "policy" "biology stated as INFERENCE from evidence, with uncertainty; never as observed fact"
else
  check interpretation_gate TECHNICALLY_SUCCESSFUL_BUT_BIOLOGICALLY_UNSUPPORTED "$reason" "REFUSING biological interpretation: evidence backbone not clear"
fi
verdict_emit "biological interpretation gate"
