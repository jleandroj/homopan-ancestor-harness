#!/usr/bin/env bash
# lib_verdict.sh -- shared verdict/evidence model for the verification agents.
#
# Philosophy: EXECUTION IS NOT TRUTH. A command exiting 0 does not make a result
# scientifically correct. Every agent emits a structured verdict where each check
# carries EVIDENCE (a file, command, hash, paper, or reproducible result). When
# evidence is missing the honest status is UNKNOWN / NOT_TESTED / INSUFFICIENT_
# EVIDENCE -- never a fabricated PASS.
#
# Source from every agent:  source "$(dirname "$0")/lib_verdict.sh"
# Each agent writes ONE verdict JSON file: ${VDIR}/<agent>.verdict.json
set -uo pipefail

AG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${AG_DIR}/.." && pwd)"
# Verification context: one directory per verification run (holds verdicts +
# the evidence ledger + the claims under test).
VRUN="${VERIFY_RUN_DIR:-${ROOT}/.harness/verify/$(date +%Y%m%d_%H%M%S)_$$}"
VDIR="${VRUN}/verdicts"
LEDGER="${VRUN}/evidence_ledger.jsonl"
mkdir -p "${VDIR}" 2>/dev/null || true

# ── Canonical statuses (the only honest outcomes) ─────────────────────────
#   PASS                          checked, evidence present, passed
#   PASS_EXPLORATORY              passed but exploratory-only (not confirmatory)
#   FAIL_TECHNICAL                the step/tool failed
#   FAIL_REPRODUCIBILITY          result not reproducible
#   FAIL_EVIDENCE                 a claim lacks evidence
#   FAIL_SECURITY                 a security boundary was violated
#   FAIL_VALIDATION               domain validation failed (e.g. degenerate ancestor)
#   UNKNOWN | NOT_TESTED | INSUFFICIENT_EVIDENCE | NOT_REPRODUCIBLE |
#   TECHNICALLY_SUCCESSFUL_BUT_BIOLOGICALLY_UNSUPPORTED | EXPLORATORY_ONLY
# Rank: higher = worse / more blocking.
_rank() { case "$1" in
  PASS) echo 0;; PASS_EXPLORATORY|EXPLORATORY_ONLY) echo 1;;
  NOT_TESTED|UNKNOWN|INSUFFICIENT_EVIDENCE|NOT_REPRODUCIBLE|TECHNICALLY_SUCCESSFUL_BUT_BIOLOGICALLY_UNSUPPORTED) echo 2;;
  FAIL_VALIDATION|FAIL_EVIDENCE|FAIL_REPRODUCIBILITY) echo 3;;
  FAIL_TECHNICAL) echo 4;; FAIL_SECURITY) echo 5;; *) echo 2;; esac; }

# Prefer a CAPABLE jq: the snap-confined /snap/bin/jq cannot open files under
# .harness/ (permission denied), so try conda/usr jq FIRST and fall back to a
# PATH jq only if it is not the snap build.
_jq() { local j
        for j in "${HOME}/miniconda3/envs/homopan_ancestor/bin/jq" /usr/bin/jq /usr/local/bin/jq; do
          [ -x "$j" ] && { "$j" "$@"; return; }; done
        j="$(command -v jq 2>/dev/null)"
        [ -n "$j" ] && [[ "$j" != /snap/* ]] && { "$j" "$@"; return; }
        return 1; }
_esc() { python3 -c 'import json,sys;print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null \
         || sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '; }

# ── Per-agent verdict accumulation ────────────────────────────────────────
# Usage in an agent:
#   verdict_init "InputIntegrityAgent"
#   check "fasta_exists" PASS "genomes/human.fa" "exists, 3.0G"
#   check "gtf_present"  NOT_TESTED "" "no GTF required for this run"
#   verdict_emit "summary line"
_AGENT=""; _CHECKS_FILE=""
verdict_init() { _AGENT="$1"; _CHECKS_FILE="$(mktemp)"; }
# check <name> <status> <evidence> <detail>
check() {
  local name="$1" status="$2" evidence="${3:-}" detail="${4:-}"
  # Field separator is ASCII Unit Separator (0x1f), NOT tab: tab is IFS whitespace
  # so an empty middle field (e.g. empty evidence) would collapse on read and
  # shift the columns. 0x1f is non-whitespace and never appears in our text.
  printf '%s\x1f%s\x1f%s\x1f%s\n' "$name" "$status" "$evidence" "$detail" >> "${_CHECKS_FILE}"
  # mirror to the global evidence ledger (append-only)
  printf '{"ts":"%s","agent":"%s","check":"%s","status":"%s","evidence":"%s","detail":"%s"}\n' \
    "$(date -Iseconds)" "${_AGENT}" "$name" "$status" \
    "$(printf '%s' "$evidence" | _esc)" "$(printf '%s' "$detail" | _esc)" >> "${LEDGER}" 2>/dev/null || true
}
# Worst (highest-rank) status across this agent's checks = the agent status.
verdict_emit() {
  local summary="${1:-}" worst="PASS" wr=0 line st r out
  while IFS=$'\x1f' read -r name status evidence detail; do
    r=$(_rank "$status"); (( r > wr )) && { wr=$r; worst="$status"; }
  done < "${_CHECKS_FILE}"
  out="${VDIR}/${_AGENT}.verdict.json"
  {
    printf '{"agent":"%s","status":"%s","ts":"%s","summary":"%s","checks":[' \
      "${_AGENT}" "${worst}" "$(date -Iseconds)" "$(printf '%s' "$summary" | _esc)"
    local first=1
    while IFS=$'\x1f' read -r name status evidence detail; do
      [ -z "$name" ] && continue
      [ $first -eq 1 ] && first=0 || printf ','
      printf '{"name":"%s","status":"%s","evidence":"%s","detail":"%s"}' \
        "$name" "$status" "$(printf '%s' "$evidence" | _esc)" "$(printf '%s' "$detail" | _esc)"
    done < "${_CHECKS_FILE}"
    printf ']}\n'
  } > "${out}"
  rm -f "${_CHECKS_FILE}"
  echo "[${_AGENT}] ${worst} -- ${summary}" >&2
  echo "${worst}"   # stdout = the agent status (coordinator captures it)
}

export VRUN VDIR LEDGER ROOT AG_DIR
