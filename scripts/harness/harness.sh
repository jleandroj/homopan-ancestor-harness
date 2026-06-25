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
  # Iteration 10: hash-chain each line to the previous one (tamper-evidence).
  local args=(--arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
              --arg run_id "${HARNESS_RUN_ID:-unknown}" \
              --argjson seq "${HARNESS_SEQ}" --arg type "${type}" \
              --arg prev "${HARNESS_PREV_HASH:-genesis}")
  local obj='{ts:$ts, run_id:$run_id, seq:$seq, type:$type, prev:$prev}'
  while (( $# >= 2 )); do
    local k="$1" v="$2"; shift 2
    args+=(--arg "k_${k}" "${v}")
    obj="${obj} + {${k}:\$k_${k}}"
  done
  local line
  line="$("${jq}" -cn "${args[@]}" "${obj}" 2>/dev/null)" || \
    line="{\"ts\":\"$(date -u +%FT%TZ)\",\"run_id\":\"${HARNESS_RUN_ID:-unknown}\",\"seq\":${HARNESS_SEQ},\"type\":\"${type}\",\"prev\":\"${HARNESS_PREV_HASH:-genesis}\",\"_logerr\":1}"
  # this line's hash becomes the link for the next one
  HARNESS_PREV_HASH="$(printf '%s' "${line}" | sha256sum | cut -d' ' -f1)"
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

# ── Iteration 3: harness_exec -- the single execution path ─────────────────
# EVERY action must run through this. It captures stdout+stderr to per-action
# files, measures wall-clock duration, records start/end + exit code + output
# hashes in the audit log, and returns the command's own exit code. Nothing the
# agent does should bypass it; if it does, there is no audit trail for it.
# ── Iteration 4: deny-by-default allowlist ─────────────────────────────────
# The supervisor refuses to execute any program whose basename is not on the
# allowlist, and logs the denial. Assume bad faith: an agent that asks to run
# `nc`, `curl`, a miner, etc. is stopped here, not trusted.
harness_allowed() {   # <program>
  [[ "${HARNESS_ALLOWLIST_OFF:-0}" == "1" ]] && return 0
  local prog; prog="$(basename -- "$1" 2>/dev/null)"
  local list="${HARNESS_ALLOWLIST:-}"
  if [[ -z "${list}" ]]; then
    local f="${HARNESS_ALLOWLIST_FILE:-${HARNESS_DIR}/allowlist.txt}"
    [[ -f "$f" ]] && list="$(grep -vE '^\s*#|^\s*$' "$f" 2>/dev/null | tr '\n' ' ')"
  fi
  local a
  for a in ${list}; do [[ "${prog}" == "${a}" ]] && return 0; done
  return 1
}

# Can this host actually create a sandbox? (unprivileged userns probe)
harness_sandbox_ok() {
  local bw="${HOMOPAN_BWRAP_BIN:-bwrap}"
  command -v "${bw}" >/dev/null 2>&1 || return 1
  "${bw}" --unshare-user --unshare-net --ro-bind /usr /usr --tmpfs /tmp true >/dev/null 2>&1
}

harness_exec() {
  [[ "${1:-}" == "--" ]] && shift
  (( $# >= 1 )) || { echo "harness_exec: no command" >&2; return 64; }
  if ! harness_allowed "$1"; then
    harness_log "denied" cmd "$*" reason "program not in allowlist" program "$(basename -- "$1")"
    echo "harness: DENIED '$(basename -- "$1")' -- not in allowlist." >&2
    return 126
  fi
  # ── Iteration 7: real sandbox (bwrap) integration, fail-closed ───────────
  # HARNESS_SANDBOX != 0 -> run the action inside scripts/sandbox_run.sh (the
  # no-egress bwrap boundary). If a sandbox is requested but the host cannot
  # provide one, DENY (fail-closed) unless HARNESS_ALLOW_UNSANDBOXED=1 (recorded).
  local sbprefix=()
  if [[ "${HARNESS_SANDBOX:-0}" != "0" ]]; then
    if harness_sandbox_ok; then
      sbprefix=(bash "${HARNESS_ROOT}/scripts/sandbox_run.sh")
      harness_log "sandbox" cmd "$*" mode "on"
    elif [[ "${HARNESS_ALLOW_UNSANDBOXED:-0}" == "1" ]]; then
      harness_log "sandbox" cmd "$*" mode "DISABLED-by-override"
    else
      harness_log "denied" cmd "$*" reason "sandbox requested but host cannot sandbox (fail-closed)"
      echo "harness: DENIED -- sandbox requested but host lacks userns/bwrap. Set HARNESS_ALLOW_UNSANDBOXED=1 to run unsandboxed (recorded)." >&2
      return 126
    fi
  fi
  # ── Iteration 5: kill-switch + per-action timeout ───────────────────────
  # Kill-switch: a sentinel file (per-run or global) halts execution before any
  # further action -- a human or watchdog can stop a runaway agent instantly.
  local killf="${HARNESS_KILL_FILE:-${HARNESS_RUN_DIR}/KILL}"
  if [[ -e "${killf}" ]]; then
    harness_log "killed" cmd "$*" reason "kill-switch present" file "${killf}"
    echo "harness: KILL-SWITCH active (${killf}); refusing to execute." >&2
    return 137
  fi
  local seq=$((HARNESS_SEQ+1))   # the action_start log will consume this seq
  local out="${HARNESS_RUN_DIR}/action_${seq}.out"
  local err="${HARNESS_RUN_DIR}/action_${seq}.err"
  local cmdstr="$*"
  local tmo="${HARNESS_TIMEOUT:-0}"   # seconds; 0 = no timeout
  harness_log "action_start" cmd "${cmdstr}" timeout_s "${tmo}" stdout "$(basename "${out}")" stderr "$(basename "${err}")"
  # ── Iteration 6: resource limits (rlimits) ──────────────────────────────
  # Apply rlimits in the child subshell so a misbehaving action cannot exhaust
  # CPU/RAM/disk/PIDs and take down the host. Each limit is opt-in (set the env);
  # what was applied is recorded. Defaults are off so legitimate heavy steps
  # (Cactus) are not silently starved -- the operator sets limits per workload.
  local t0 t1 rc dur
  local _to_timeout=0; [[ "${tmo}" != "0" ]] && command -v timeout >/dev/null 2>&1 && _to_timeout=1
  harness_log "limits" cmd "${cmdstr}" cpu_s "${HARNESS_LIM_CPU:-none}" mem_mb "${HARNESS_LIM_MEM_MB:-none}" \
    fsize_mb "${HARNESS_LIM_FSIZE_MB:-none}" nproc "${HARNESS_LIM_NPROC:-none}"
  t0="$(date +%s%3N 2>/dev/null || date +%s000)"
  (
    [[ -n "${HARNESS_LIM_CPU:-}" ]]     && ulimit -t "${HARNESS_LIM_CPU}" 2>/dev/null || true
    [[ -n "${HARNESS_LIM_MEM_MB:-}" ]]  && ulimit -v "$(( HARNESS_LIM_MEM_MB * 1024 ))" 2>/dev/null || true
    [[ -n "${HARNESS_LIM_FSIZE_MB:-}" ]]&& ulimit -f "$(( HARNESS_LIM_FSIZE_MB * 1024 ))" 2>/dev/null || true
    [[ -n "${HARNESS_LIM_NPROC:-}" ]]   && ulimit -u "${HARNESS_LIM_NPROC}" 2>/dev/null || true
    ulimit -c 0 2>/dev/null || true   # never dump cores
    if (( _to_timeout )); then exec timeout --kill-after=10 "${tmo}" "${sbprefix[@]}" "$@"; else exec "${sbprefix[@]}" "$@"; fi
  ) >"${out}" 2>"${err}"
  rc=$?
  t1="$(date +%s%3N 2>/dev/null || date +%s000)"
  dur=$(( t1 - t0 ))
  if [[ ${rc} -eq 124 ]]; then
    harness_log "timeout" cmd "${cmdstr}" timeout_s "${tmo}" duration_ms "${dur}"
  fi
  local osha esha
  osha="$(sha256sum "${out}" 2>/dev/null | cut -d' ' -f1)"; esha="$(sha256sum "${err}" 2>/dev/null | cut -d' ' -f1)"
  harness_log "action_end" cmd "${cmdstr}" exit "${rc}" duration_ms "${dur}" \
    out_bytes "$(wc -c <"${out}" 2>/dev/null || echo 0)" err_bytes "$(wc -c <"${err}" 2>/dev/null || echo 0)" \
    out_sha256 "${osha:-}" err_sha256 "${esha:-}" \
    outcome "$([[ ${rc} -eq 0 ]] && echo ok || echo error)"
  return "${rc}"
}

# ── Iteration 8: bounded retry + crash isolation ───────────────────────────
# A transient failure is retried with backoff (bounded). The action always runs
# in a child subshell, so even a crash/segfault/kill of the action cannot take
# down the supervisor -- it is observed as a non-zero exit, logged, and (if
# retries remain) retried. The harness itself traps signals so an interrupt is
# recorded, not silent.
harness_exec_retry() {
  local tries="${HARNESS_RETRIES:-0}" backoff="${HARNESS_BACKOFF_S:-3}" attempt=0 rc=0
  while :; do
    attempt=$((attempt+1))
    harness_exec "$@"; rc=$?
    # do not retry policy denials (126) or kill-switch (137) -- those are decisions
    if [[ ${rc} -eq 0 || ${rc} -eq 126 || ${rc} -eq 137 ]]; then break; fi
    if (( attempt > tries )); then break; fi
    harness_log "retry" cmd "$*" attempt "${attempt}" of "${tries}" last_exit "${rc}" backoff_s "${backoff}"
    sleep "${backoff}" 2>/dev/null || true
  done
  return "${rc}"
}

harness_on_signal() {   # trap handler: record, then exit non-zero (don't die silent)
  harness_log "interrupted" signal "${1:-?}"
  HARNESS_INTERRUPTED=1
  return 0
}

# ── Iteration 10: tamper-evident audit log (hash-chain verification) ───────
# Each line carries prev = sha256 of the previous line, so deleting, editing, or
# reordering ANY line breaks the chain. Returns 0 if intact, 1 if tampered.
harness_verify_log() {   # <audit.jsonl>
  local audit="${1}" jq prev="genesis" ln exp n=0 bad=0
  jq="$(harness_jq)"
  [[ -f "${audit}" ]] || { echo "verify: no audit log: ${audit}" >&2; return 2; }
  while IFS= read -r ln; do
    n=$((n+1))
    exp="$(printf '%s' "${ln}" | "${jq}" -r '.prev // "MISSING"' 2>/dev/null)"
    if [[ "${exp}" != "${prev}" ]]; then
      echo "TAMPER at line ${n}: chain expected prev=${prev:0:12}, found ${exp:0:12}" >&2; bad=1
    fi
    prev="$(printf '%s' "${ln}" | sha256sum | cut -d' ' -f1)"
  done < "${audit}"
  # Gap #1: cross-check the chain HEAD + line count against the EXTERNAL anchor.
  # A tamperer who edits a line and recomputes all downstream hashes makes the
  # local chain self-consistent, but the final head changes -> it no longer
  # matches the head anchored in the external append-only log (which an admin
  # can chattr +a). Editing that too is out of the agent's reach.
  local ext="${2:-${HOMOPAN_AUDIT_LOG:-${HOME}/.homopan_audit.jsonl}}"
  local rid; rid="$(head -1 "${audit}" 2>/dev/null | "${jq}" -r '.run_id // ""' 2>/dev/null)"
  if [[ -f "${ext}" && -n "${rid}" ]]; then
    local anchor; anchor="$(grep -F '"type":"anchor"' "${ext}" 2>/dev/null | grep -F "\"run_id\":\"${rid}\"" | tail -1)"
    if [[ -n "${anchor}" ]]; then
      local ah al; ah="$(printf '%s' "${anchor}" | "${jq}" -r '.head' 2>/dev/null)"; al="$(printf '%s' "${anchor}" | "${jq}" -r '.lines' 2>/dev/null)"
      if [[ "${prev}" != "${ah}" || "${n}" != "${al}" ]]; then
        echo "TAMPER vs EXTERNAL ANCHOR: head ${prev:0:12}!=${ah:0:12} or lines ${n}!=${al}" >&2; bad=1
      else echo "external anchor matches (head+lines)"; fi
    fi
  fi
  (( bad == 0 )) && { echo "audit log intact (${n} lines, chain verified)"; return 0; } || return 1
}

# Gap #1: anchor the final chain head + line count to the external append-only log.
harness_anchor() {
  local ext="${HOMOPAN_AUDIT_LOG:-${HOME}/.homopan_audit.jsonl}"; local jq; jq="$(harness_jq)"
  local line; line="$("${jq}" -cn --arg rid "${HARNESS_RUN_ID:-unknown}" \
    --argjson lines "${HARNESS_SEQ:-0}" --arg head "${HARNESS_PREV_HASH:-genesis}" \
    --arg ts "$(date -u +%FT%TZ)" '{type:"anchor", run_id:$rid, lines:$lines, head:$head, ts:$ts}' 2>/dev/null)"
  [[ -n "${line}" ]] && printf '%s\n' "${line}" >> "${ext}" 2>/dev/null || true
}

# ── Iteration 9: automatic report on completion OR failure ─────────────────
# Aggregates the audit log into report.json (machine) + report.md (human),
# surfacing every problem (errors, denials, timeouts, kills, interrupts) and a
# top-line status. Generated from an EXIT trap so it exists even if the run
# crashed or was interrupted.
harness_report() {
  [[ -n "${HARNESS_RUN_DIR:-}" && -d "${HARNESS_RUN_DIR}" ]] || return 0
  local audit="${HARNESS_RUN_DIR}/audit.jsonl"
  [[ -f "${audit}" ]] || return 0
  local jq; jq="$(harness_jq)"
  "${jq}" -s '
    def cnt($t): ([.[]|select(.type==$t)]|length);
    {
      run_id: (.[0].run_id // "unknown"),
      argv: ([.[]|select(.type=="start")|.argv][0] // ""),
      actions: cnt("action_end"),
      errors:  ([.[]|select(.type=="action_end" and .exit!="0")]|length),
      denials: cnt("denied"), timeouts: cnt("timeout"), kills: cnt("killed"),
      retries: cnt("retry"), interrupted: cnt("interrupted"),
      total_duration_ms: ([.[]|select(.type=="action_end")|(.duration_ms|tonumber? // 0)]|add // 0)
    }
    | .problems = (.errors + .denials + .timeouts + .kills + .interrupted)
    | .status = (if .problems>0 then "PROBLEMS" else "OK" end)
  ' < "${audit}" > "${HARNESS_RUN_DIR}/report.json" 2>/dev/null || return 0
  # fold in tamper-evidence verdict (iter 10)
  local integ; if harness_verify_log "${audit}" >/dev/null 2>&1; then integ="intact"; else integ="TAMPERED"; fi
  "${jq}" --arg i "${integ}" '. + {integrity:$i}' < "${HARNESS_RUN_DIR}/report.json" > "${HARNESS_RUN_DIR}/report.json.tmp" 2>/dev/null \
    && mv -f "${HARNESS_RUN_DIR}/report.json.tmp" "${HARNESS_RUN_DIR}/report.json"
  # human-readable
  {
    local r="${HARNESS_RUN_DIR}/report.json"
    echo "# Harness run report"
    echo
    echo "- run_id: $("${jq}" -r '.run_id' < "${r}")"
    echo "- status: **$("${jq}" -r '.status' < "${r}")**"
    echo "- command: \`$("${jq}" -r '.argv' < "${r}")\`"
    echo "- actions: $("${jq}" -r '.actions' < "${r}")  | total: $("${jq}" -r '.total_duration_ms' < "${r}") ms"
    echo "- problems: errors=$("${jq}" -r '.errors' < "${r}") denials=$("${jq}" -r '.denials' < "${r}") timeouts=$("${jq}" -r '.timeouts' < "${r}") kills=$("${jq}" -r '.kills' < "${r}") interrupted=$("${jq}" -r '.interrupted' < "${r}") retries=$("${jq}" -r '.retries' < "${r}")"
    echo
    echo "## Failed / flagged actions"
    "${jq}" -r 'select(.type=="action_end" and .exit!="0") | "- FAIL exit=\(.exit) dur=\(.duration_ms)ms cmd=\(.cmd)"' < "${audit}" 2>/dev/null
    "${jq}" -r 'select(.type=="denied") | "- DENIED \(.reason): \(.cmd)"' < "${audit}" 2>/dev/null
    "${jq}" -r 'select(.type=="timeout") | "- TIMEOUT (\(.timeout_s)s): \(.cmd)"' < "${audit}" 2>/dev/null
    echo
    echo "_Full audit: audit.jsonl · per-action stdout/stderr: action_*.out/.err_"
  } > "${HARNESS_RUN_DIR}/report.md" 2>/dev/null || true
  return 0
}

# CLI
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    id)   harness_runid ;;
    init) harness_init && echo "${HARNESS_RUN_DIR}" ;;
    run)  shift; harness_init || exit 70; harness_seal_audit
          HARNESS_INTERRUPTED=0
          trap 'harness_on_signal INT'  INT
          trap 'harness_on_signal TERM' TERM
          trap 'harness_report' EXIT      # report on success, failure, OR crash
          harness_log "start" argv "$*"
          # The supervisor must survive the action's failure: run under a guard
          # so a non-zero/crash never aborts the harness (no set -e here anyway).
          harness_exec_retry "$@"; rc=$?
          harness_log "end" exit "${rc}" interrupted "${HARNESS_INTERRUPTED:-0}"
          harness_anchor   # anchor chain head+count to the external append-only log
          echo "run_id=${HARNESS_RUN_ID} dir=${HARNESS_RUN_DIR} exit=${rc}" >&2
          exit "${rc}" ;;
    kill) shift; kf="${1:?usage: harness.sh kill <run_dir>}/KILL"; : > "${kf}" && echo "kill-switch set: ${kf}" ;;
    verify) shift; harness_verify_log "${1:?usage: harness.sh verify <run_dir>/audit.jsonl or <run_dir>}"$([[ -d "${1}" ]] && echo "/audit.jsonl") ;;
    *)    echo "usage: harness.sh {id|init|run -- <cmd...>|kill <run_dir>|verify <run_dir>}" >&2; exit 2 ;;
  esac
fi
