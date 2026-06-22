#!/usr/bin/env bash
# harness.sh -- production supervisor for agent/pipeline execution.
#
# Design goals (in priority order):
#   1. Complete audit log   -- every action logged (JSON, append-only, timestamped)
#   2. Automatic report     -- summary on success OR failure
#   3. Containment          -- nothing runs except through harness_exec (sandbox,
#                              rlimits, allowlist, timeout, kill-switch)
#   4. Traceability         -- unique run id; a past run is fully reconstructable
#   5. Robustness           -- errors caught; agent failure never kills the harness
#
# This file is a LIBRARY (source it) and a DRIVER:
#   source scripts/harness/harness.sh; harness_init; harness_exec -- mycmd args...
#   bash scripts/harness/harness.sh run -- mycmd args...
#
# Built iteratively; each iteration adds one capability and keeps it functional.
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "${HARNESS_DIR}/../.." && pwd)"

# ── Iteration 1: run context + unique id + per-run directory ───────────────
# A unique, sortable run id (UTC timestamp + pid + random) and an isolated
# directory hold everything about one supervised run, so any execution can be
# located and reconstructed later.
harness_runid() {
  local ts rnd
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  rnd="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%04x%04x' "${RANDOM}" "${RANDOM}")"
  printf 'run_%s_%s_%s' "${ts}" "$$" "${rnd}"
}

harness_init() {
  HARNESS_RUN_ID="${HARNESS_RUN_ID:-$(harness_runid)}"
  HARNESS_BASE="${HARNESS_BASE:-${HARNESS_ROOT}/runs/_harness}"
  HARNESS_RUN_DIR="${HARNESS_BASE}/${HARNESS_RUN_ID}"
  mkdir -p "${HARNESS_RUN_DIR}" || { echo "FATAL: cannot create run dir ${HARNESS_RUN_DIR}" >&2; return 1; }
  export HARNESS_RUN_ID HARNESS_RUN_DIR HARNESS_BASE
  # Immutable run metadata (best-effort fields; never fails the run).
  {
    printf '{'
    printf '"run_id":"%s",' "${HARNESS_RUN_ID}"
    printf '"started_at":"%s",' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '"host":"%s",' "$(hostname 2>/dev/null || echo unknown)"
    printf '"user":"%s",' "${USER:-$(id -un 2>/dev/null || echo unknown)}"
    printf '"pid":%s,' "$$"
    printf '"harness_version":"%s",' "${HARNESS_VERSION:-1}"
    printf '"git_commit":"%s",' "$(git -C "${HARNESS_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf '"cwd":"%s"' "${PWD}"
    printf '}\n'
  } > "${HARNESS_RUN_DIR}/run.json"
  return 0
}

# ── Iteration 2: capable jq + structured append-only audit log ─────────────
# The host `jq` may be the snap build, which is confined and CANNOT open
# file-path args (Permission denied). Resolve a capable jq once and ALWAYS feed
# it via stdin. Audit events are JSON Lines, append-only, sequenced, and locked
# so concurrent writers never interleave; we also try to make the file truly
# append-only (chattr +a) so even the agent cannot rewrite history.
harness_jq() {
  if [[ -z "${HARNESS_JQ:-}" ]]; then
    local c
    for c in "${HOMOPAN_JQ:-}" "${HOME}/miniconda3/envs/homopan_ancestor/bin/jq" \
             "${HOME}/miniconda3/bin/jq" /usr/bin/jq jq; do
      [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1 && { HARNESS_JQ="$c"; break; }
    done
    : "${HARNESS_JQ:=jq}"
  fi
  printf '%s' "${HARNESS_JQ}"
}

HARNESS_SEQ=0
harness_log() {   # <type> [k v k v ...]  -> appends one JSON object to audit.jsonl
  local type="$1"; shift || true
  local audit="${HARNESS_RUN_DIR}/audit.jsonl"
  local ext="${HOMOPAN_AUDIT_LOG:-${HOME}/.homopan_audit.jsonl}"
  HARNESS_SEQ=$((HARNESS_SEQ+1))
  local jq; jq="$(harness_jq)"
  # Build args as --arg pairs (all values are strings; callers pre-stringify).
  local args=(--arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
              --arg run_id "${HARNESS_RUN_ID:-unknown}" \
              --argjson seq "${HARNESS_SEQ}" --arg type "${type}")
  local obj='{ts:$ts, run_id:$run_id, seq:$seq, type:$type}'
  while (( $# >= 2 )); do
    local k="$1" v="$2"; shift 2
    args+=(--arg "k_${k}" "${v}")
    obj="${obj} + {${k}:\$k_${k}}"
  done
  local line
  line="$("${jq}" -cn "${args[@]}" "${obj}" 2>/dev/null)" || \
    line="{\"ts\":\"$(date -u +%FT%TZ)\",\"run_id\":\"${HARNESS_RUN_ID:-unknown}\",\"seq\":${HARNESS_SEQ},\"type\":\"${type}\",\"_logerr\":1}"
  # Append under flock so concurrent actions never interleave a line.
  if command -v flock >/dev/null 2>&1; then
    ( flock 9; printf '%s\n' "${line}" >> "${audit}" ) 9>>"${audit}.lock" 2>/dev/null || printf '%s\n' "${line}" >> "${audit}" 2>/dev/null || true
  else
    printf '%s\n' "${line}" >> "${audit}" 2>/dev/null || true
  fi
  printf '%s\n' "${line}" >> "${ext}" 2>/dev/null || true
}

# Make the per-run audit log append-only if we can (defense vs. the agent
# rewriting its own history). Best-effort: chattr needs privileges on some FS.
harness_seal_audit() {
  local audit="${HARNESS_RUN_DIR}/audit.jsonl"
  [[ -e "${audit}" ]] || : > "${audit}"
  chattr +a "${audit}" 2>/dev/null || true
}

# CLI
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    id)   harness_runid ;;
    init) harness_init && echo "${HARNESS_RUN_DIR}" ;;
    *)    echo "usage: harness.sh {id|init}" >&2; exit 2 ;;
  esac
fi
