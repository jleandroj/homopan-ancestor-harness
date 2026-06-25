#!/usr/bin/env bash
# lib_agent.sh -- shared library for the verification agents.
#
# Philosophy: EXECUTION IS NOT TRUTH. Every agent emits a structured VERDICT and
# must prefer an honest non-answer (UNKNOWN / NOT_TESTED / INSUFFICIENT_EVIDENCE)
# over claiming PASS without evidence. A reconstructed ancestor is never an
# observed genome; a non-reproducible result is never biological evidence.
#
# An agent script sources this lib, calls agent_begin, records evidence/findings,
# and ends with agent_emit <status> "<summary>". The single JSON verdict goes to
# stdout (the Coordinator slurps it) and, if a harness run is active, to the
# tamper-evident audit log.

# ── Canonical statuses ─────────────────────────────────────────────────────
# Terminal (gate-relevant), ordered loosely worst->best for the Coordinator.
AGENT_STATUSES="FAIL_SECURITY FAIL_TECHNICAL FAIL_REPRODUCIBILITY FAIL_EVIDENCE FAIL_VALIDATION INSUFFICIENT_EVIDENCE NOT_TESTED UNKNOWN PASS_EXPLORATORY PASS"

agent_jq() {
  if [[ -z "${AGENT_JQ:-}" ]]; then
    local c
    for c in "${HOMOPAN_JQ:-}" "${HOME}/miniconda3/envs/homopan_ancestor/bin/jq" /usr/bin/jq jq; do
      [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1 && { AGENT_JQ="$c"; break; }
    done
    : "${AGENT_JQ:=jq}"
  fi
  printf '%s' "${AGENT_JQ}"
}

# agent_begin <name>
agent_begin() {
  AGENT_NAME="$1"
  AGENT_EVIDENCE=()     # strings: "kind:detail"
  AGENT_FINDINGS=()     # strings: human-readable issues
}

# agent_evidence <kind> <detail>   -- a concrete, checkable fact (file/cmd/hash/db)
agent_evidence() { AGENT_EVIDENCE+=("$1: $2"); }
# agent_finding <text>             -- a problem the agent observed
agent_finding()  { AGENT_FINDINGS+=("$1"); }

# agent_emit <status> <summary>    -- print the verdict JSON; log it; set rc
agent_emit() {
  local status="$1" summary="${2:-}"; local jq; jq="$(agent_jq)"
  local args=(--arg agent "${AGENT_NAME:-unknown}" --arg status "${status}" \
              --arg summary "${summary}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
  local ev_json fn_json
  ev_json="$(printf '%s\n' "${AGENT_EVIDENCE[@]:-}" | "${jq}" -R . 2>/dev/null | "${jq}" -cs 'map(select(length>0))' 2>/dev/null || echo '[]')"
  fn_json="$(printf '%s\n' "${AGENT_FINDINGS[@]:-}" | "${jq}" -R . 2>/dev/null | "${jq}" -cs 'map(select(length>0))' 2>/dev/null || echo '[]')"
  local line
  line="$("${jq}" -cn "${args[@]}" --argjson ev "${ev_json:-[]}" --argjson fn "${fn_json:-[]}" \
    '{agent:$agent, status:$status, summary:$summary, ts:$ts, evidence:$ev, findings:$fn}' 2>/dev/null)" \
    || line="{\"agent\":\"${AGENT_NAME:-unknown}\",\"status\":\"${status}\",\"summary\":\"${summary}\",\"evidence\":[],\"findings\":[]}"
  printf '%s\n' "${line}"
  # mirror into the harness audit log if a run is active
  if declare -F harness_log >/dev/null 2>&1 && [[ -n "${HARNESS_RUN_DIR:-}" ]]; then
    harness_log "agent_verdict" agent "${AGENT_NAME:-unknown}" status "${status}" summary "${summary}"
  fi
  # exit code: 0 only for PASS/PASS_EXPLORATORY; non-zero otherwise (honest fail-loud)
  case "${status}" in PASS|PASS_EXPLORATORY) return 0 ;; *) return 1 ;; esac
}

# Convenience: require a file; record evidence or a finding.
agent_need_file() {  # <path> <label>
  if [[ -f "$1" ]]; then agent_evidence "file" "${2:-$1} present ($(stat -c%s "$1" 2>/dev/null || echo 0) bytes)"; return 0
  else agent_finding "${2:-$1} missing: $1"; return 1; fi
}
