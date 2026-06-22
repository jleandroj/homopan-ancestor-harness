#!/usr/bin/env bash
# coordinator.sh -- orchestrates the verification agents and produces the FINAL
# decision. Core rule: NO biological conclusion is allowed unless the evidence
# agents (Provenance, Reproducibility, FactGuard, Security) PASS and the relevant
# domain agents do not FAIL. Execution success never implies scientific truth.
#
# Usage:
#   VERIFY_RUN_DIR=<ctx> agents/coordinator.sh [--claims file] [--run-dir dir]
# The context dir may contain:  claims.tsv (claims under test), a run/ to inspect.
# Produces: ${VRUN}/decision.json  +  human summary on stderr.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_verdict.sh"

# ── agent run order (dependency-first) ────────────────────────────────────
# security & inputs first; provenance/repro establish trust; domain agents;
# fact-guard gates claims; interpretation last; red-team attacks everything.
AGENTS=(
  security_sandbox
  input_integrity
  provenance
  reproducibility
  phylogeny
  ancestor_validation
  statistics
  literature
  fact_guard
  biological_interpretation
  red_team
)
# Agents whose non-PASS BLOCKS biological conclusions (the evidence backbone).
REQUIRED=(security_sandbox provenance reproducibility fact_guard)

echo "=== Coordinator: verification run ${VRUN} ===" >&2
declare -A ST
for a in "${AGENTS[@]}"; do
  s="${AG_DIR}/${a}.sh"
  if [[ -x "$s" || -f "$s" ]]; then
    st="$(VERIFY_RUN_DIR="${VRUN}" bash "$s" 2>>"${VRUN}/agents.log")" || st="FAIL_TECHNICAL"
    st="$(printf '%s' "$st" | tail -1 | tr -d '[:space:]')"
    [[ -z "$st" ]] && st="UNKNOWN"
  else
    st="NOT_TESTED"
  fi
  ST[$a]="$st"
  echo "  ${a}: ${st}" >&2
done

# ── aggregate to a final status (worst wins) ──────────────────────────────
worst="PASS"; wr=0; blockers=()
for a in "${AGENTS[@]}"; do
  r=$(_rank "${ST[$a]}")
  (( r > wr )) && { wr=$r; }
  case "${ST[$a]}" in PASS|PASS_EXPLORATORY|EXPLORATORY_ONLY|NOT_TESTED) ;; *) blockers+=("${a}:${ST[$a]}");; esac
done
# map worst rank -> final status
case "${wr}" in
  0) FINAL="PASS";;
  1) FINAL="PASS_EXPLORATORY";;
  2) FINAL="UNKNOWN";;
  3) FINAL="FAIL_EVIDENCE";;
  4) FINAL="FAIL_TECHNICAL";;
  5) FINAL="FAIL_SECURITY";;
  *) FINAL="UNKNOWN";;
esac
# refine: a reproducibility failure is named explicitly
[[ "${ST[reproducibility]:-}" == FAIL_REPRODUCIBILITY || "${ST[reproducibility]:-}" == NOT_REPRODUCIBLE ]] && (( wr<=3 )) && FINAL="FAIL_REPRODUCIBILITY"

# ── biological-conclusion gate ────────────────────────────────────────────
bio_ok="true"; bio_reason=""
for a in "${REQUIRED[@]}"; do
  case "${ST[$a]:-NOT_TESTED}" in PASS) ;; *) bio_ok="false"; bio_reason="${bio_reason}${a}=${ST[$a]:-NOT_TESTED}; ";; esac
done
[[ "${FINAL}" == PASS || "${FINAL}" == PASS_EXPLORATORY ]] || bio_ok="false"

# ── decision object ───────────────────────────────────────────────────────
DEC="${VRUN}/decision.json"
{
  printf '{"final_status":"%s","biological_conclusions_allowed":%s,' "${FINAL}" "${bio_ok}"
  printf '"bio_block_reason":"%s","ts":"%s","verify_run":"%s",' "$(printf '%s' "${bio_reason}" | _esc)" "$(date -Iseconds)" "${VRUN}"
  printf '"agent_status":{'
  first=1; for a in "${AGENTS[@]}"; do [ $first -eq 1 ] && first=0 || printf ','; printf '"%s":"%s"' "$a" "${ST[$a]}"; done
  printf '},"blockers":['
  first=1; for b in "${blockers[@]:-}"; do [ -z "$b" ] && continue; [ $first -eq 1 ] && first=0 || printf ','; printf '"%s"' "$b"; done
  printf ']}\n'
} > "${DEC}"

echo "" >&2
echo "=== FINAL: ${FINAL} === biological_conclusions_allowed=${bio_ok}" >&2
[[ "${bio_ok}" == "false" && -n "${bio_reason}" ]] && echo "  bloqueado por: ${bio_reason}" >&2
echo "decision: ${DEC}" >&2
# Report agent renders the human-facing report from the verdicts + decision.
[[ -f "${AG_DIR}/report.sh" ]] && VERIFY_RUN_DIR="${VRUN}" bash "${AG_DIR}/report.sh" >/dev/null 2>&1 || true
echo "${FINAL}"
# exit non-zero on any blocking failure so callers/CI can gate
case "${FINAL}" in PASS|PASS_EXPLORATORY) exit 0;; UNKNOWN) exit 10;; *) exit 20;; esac
