#!/usr/bin/env bash
# harness_run.sh -- the single sanctioned entrypoint for ANY agent command.
#
# Production-grade control layer. Assume BAD FAITH from the agent: the harness
# must catch failure/misbehaviour, never crash, and record everything.
#
# Guarantees (priority order):
#   1. AUDIT       every action -> one append-only JSON line (run_id, ts, cmd,
#                  input hash, output hash+snippet, duration, exit, ok/fail).
#   2. REPORT      on finish/fail, a structured per-run report (+ desktop notify).
#   3. CONTAINMENT bwrap (no net / no $HOME) + ulimit caps + timeout + kill-switch.
#   4. TRACEABILITY unique run_id; full reconstruction from the audit log.
#   5. ROBUSTNESS  retries w/ backoff; total trap; the runner survives anything.
#
# Usage: scripts/harness_run.sh [--label N] [--no-sandbox] [--allow-net]
#                               [--retries N] [--timeout S] -- <cmd> [args...]
# NOT `set -e`: we must outlive command failures and still log/report.
set -uo pipefail

HR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HR_DIR}/.." && pwd)"
HSTATE="${ROOT}/.harness"; mkdir -p "${HSTATE}/runs" "${ROOT}/logs" 2>/dev/null || true
AUDIT="${HARNESS_AUDIT_LOG:-${HOME}/.harness_audit.jsonl}"
FEED="${ROOT}/logs/activity.feed"
KILL="${HSTATE}/KILL"
SANDBOX_RUN="${HR_DIR}/sandbox_run.sh"

JQ=""
for c in "${HOMEPAN_JQ:-}" jq "${HOME}/miniconda3/envs/homopan_ancestor/bin/jq" /usr/bin/jq; do
  command -v "$c" >/dev/null 2>&1 && { JQ="$c"; break; }; [[ -n "$c" && -x "$c" ]] && { JQ="$c"; break; }
done

# ITER 1: traceability -- unique run id
RUN_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || printf '%s_%s' "$(date +%s%N)" "$$")"
RUN_DIR="${HSTATE}/runs/${RUN_ID}"; mkdir -p "${RUN_DIR}"
AGENT_TAG="${AI_AGENT:-${CLAUDE_AGENT:-unknown}}"
SESSION_TAG="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"

redact() {
  sed -E -e 's/AKIA[0-9A-Z]{16}/<AWS_KEY>/g' \
    -e 's/gh[pousr]_[A-Za-z0-9]{20,}/<GH_TOKEN>/g' -e 's/sk-[A-Za-z0-9]{20,}/<API_KEY>/g' \
    -e 's/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}/<JWT>/g' \
    -e 's/(([Pp]ass(word|wd)?|[Tt]oken|[Ss]ecret|[Aa]pi[_-]?[Kk]ey)[[:space:]]*[=:][[:space:]]*)[^[:space:]"'"'"']+/\1<REDACTED>/g' 2>/dev/null
}
json_str() { if [[ -n "$JQ" ]]; then "$JQ" -Rs . | sed 's/^"//;s/"$//'; else
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '; fi; }

# ITER 2/10: append-only audit + hash chain (tamper-evident)
# seed from the last line WITHOUT its trailing newline, to match the no-newline
# hashing used for the chain (tail keeps the \n, which would desync the chain).
PREV_HASH="$(tail -1 "${AUDIT}" 2>/dev/null | tr -d '\n' | sha256sum | cut -d' ' -f1)"
audit() { # <json-fields-without-braces>
  local ts line h
  ts="$(date -Iseconds)"
  line="{\"run_id\":\"${RUN_ID}\",\"ts\":\"${ts}\",\"agent\":\"${AGENT_TAG}\",\"session\":\"${SESSION_TAG}\",\"prev\":\"${PREV_HASH:0:16}\",$1}"
  h="$(printf '%s' "$line" | sha256sum | cut -d' ' -f1)"; PREV_HASH="$h"
  if command -v flock >/dev/null 2>&1; then
    ( flock 9; printf '%s\n' "$line" >> "${AUDIT}" ) 9>"${AUDIT}.lock" 2>/dev/null || true
  else printf '%s\n' "$line" >> "${AUDIT}" 2>/dev/null || true; fi
  printf '%s\n' "$line" >> "${RUN_DIR}/audit.jsonl" 2>/dev/null || true
}
feed() { printf '%s %s %s\n' "$(date '+%H:%M:%S')" "${RUN_ID:0:8}" "$*" >> "${FEED}" 2>/dev/null || true; }
notify() { local u="$1"; shift; feed "$*"
  command -v notify-send >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]] && \
    DISPLAY="${DISPLAY}" notify-send -u "$u" "harness" "$*" >/dev/null 2>&1 || true; }

# ITER 9: anomaly detection
ANOMALIES=()
scan() { local c="$1"
  grep -Eq '(\.ssh|\.aws|\.gnupg|id_rsa|credentials|\.netrc|/etc/shadow)' <<<"$c" && ANOMALIES+=("secret-path")
  grep -Eq '(^|[^a-z])(curl|wget|nc|ncat|socat|ssh|scp|rsync)([^a-z]|$)|/dev/tcp/|urllib|socket\.' <<<"$c" && ANOMALIES+=("network")
  grep -Eq 'rm[[:space:]]+-[a-zA-Z]*[rf][a-zA-Z]*[[:space:]].*(/|\*)' <<<"$c" && ANOMALIES+=("bulk-delete")
  grep -Eq '(base64|xxd)[^|]*\|[[:space:]]*(ba)?sh|(curl|wget)[^|]*\|[[:space:]]*(ba)?sh' <<<"$c" && ANOMALIES+=("obfusc-exec")
}

LABEL="cmd"; USE_SANDBOX="${HARNESS_SANDBOX:-1}"; ALLOW_NET="${HARNESS_ALLOW_NET:-0}"
RETRIES="${HARNESS_RETRIES:-0}"; TIMEOUT="${HARNESS_TIMEOUT:-0}"
while [[ $# -gt 0 ]]; do case "$1" in
  --label) LABEL="$2"; shift 2;; --no-sandbox) USE_SANDBOX=0; shift;;
  --allow-net) ALLOW_NET=1; shift;; --retries) RETRIES="$2"; shift 2;;
  --timeout) TIMEOUT="$2"; shift 2;; --) shift; break;; *) break;;
esac; done
(( $# > 0 )) || { echo "usage: harness_run.sh [opts] -- <cmd> [args...]" >&2; exit 2; }
CMD=( "$@" ); CMD_STR="$(printf '%q ' "${CMD[@]}" | redact)"

# ITER 6: kill-switch
if [[ -f "${KILL}" ]]; then
  notify critical "KILL-SWITCH activo: rechazo ${LABEL}"
  audit "\"event\":\"refused\",\"reason\":\"kill_switch\",\"label\":\"${LABEL}\""; exit 99
fi
scan "${CMD_STR}"
ANOM_JSON="[$(printf '"%s",' "${ANOMALIES[@]}" 2>/dev/null | sed 's/,$//')]"
for a in "${ANOMALIES[@]:-}"; do [[ -n "$a" ]] && notify critical "ANOMALIA '${a}': ${CMD_STR:0:80}"; done

# ITER 4: resource caps
apply_ulimits() {
  (( ${HARNESS_CPU_SEC:-0} > 0 ))  && ulimit -t "${HARNESS_CPU_SEC}" 2>/dev/null || true
  (( ${HARNESS_MEM_MB:-0} > 0 ))   && ulimit -v "$(( HARNESS_MEM_MB * 1024 ))" 2>/dev/null || true
  (( ${HARNESS_FSIZE_MB:-0} > 0 )) && ulimit -f "$(( HARNESS_FSIZE_MB * 1024 ))" 2>/dev/null || true
}
build_exec() { local -a pre=(); (( TIMEOUT > 0 )) && pre+=(timeout -k 10 "${TIMEOUT}")
  if [[ "${USE_SANDBOX}" == "1" && -x "${SANDBOX_RUN}" ]]; then
    printf '%s\0' "${pre[@]}" bash "${SANDBOX_RUN}" "${CMD[@]}"
  else printf '%s\0' "${pre[@]}" "${CMD[@]}"; fi; }

OUT="${RUN_DIR}/stdout.log"; ERR="${RUN_DIR}/stderr.log"
START="$(date +%s%3N 2>/dev/null || echo $(( $(date +%s)*1000 )))"
audit "\"event\":\"start\",\"label\":\"${LABEL}\",\"cmd\":\"$(printf '%s' "$CMD_STR"|json_str)\",\"sandbox\":${USE_SANDBOX},\"allow_net\":${ALLOW_NET},\"timeout\":${TIMEOUT},\"anomalies\":${ANOM_JSON}"
notify normal "RUN ${LABEL}: ${CMD_STR:0:70}"

# ITER 7: retries + robustness (never crash the harness)
attempt=0; rc=0
export HARNESS_ALLOW_NET HOMEPAN_ALLOW_NET="${ALLOW_NET}"
while :; do
  attempt=$((attempt+1)); mapfile -d '' EXECV < <(build_exec)
  ( apply_ulimits; exec "${EXECV[@]}" ) >"${OUT}" 2>"${ERR}" & child=$!
  ( while kill -0 "$child" 2>/dev/null; do [[ -f "${KILL}" ]] && kill -TERM "$child" 2>/dev/null; sleep 2; done ) & watch=$!
  wait "$child"; rc=$?; kill "$watch" 2>/dev/null || true
  (( rc == 0 )) || (( attempt > RETRIES )) && break
  notify normal "RETRY ${LABEL} (exit ${rc}) ${attempt}/${RETRIES}"
  audit "\"event\":\"retry\",\"label\":\"${LABEL}\",\"attempt\":${attempt},\"exit\":${rc}"; sleep $(( attempt*5 ))
done
END="$(date +%s%3N 2>/dev/null || echo $(( $(date +%s)*1000 )))"; DUR=$(( END-START ))

# ITER 3: capture output hash/snippet/bytes
sha_of(){ sha256sum "$1" 2>/dev/null|cut -d' ' -f1; }
OB="$(wc -c < "${OUT}" 2>/dev/null||echo 0)"
(( OB > ${HARNESS_MAX_OUT_BYTES:-104857600} )) && { ANOMALIES+=("oversized-output"); notify critical "output ${OB}B en ${LABEL}"; }
OK=true; (( rc==0 )) || OK=false
audit "\"event\":\"end\",\"label\":\"${LABEL}\",\"exit\":${rc},\"ok\":${OK},\"dur_ms\":${DUR},\"attempts\":${attempt},\"out_sha256\":\"$(sha_of "${OUT}")\",\"out_bytes\":${OB},\"err_sha256\":\"$(sha_of "${ERR}")\",\"out_snippet\":\"$(tail -c 600 "${OUT}" 2>/dev/null|redact|json_str)\",\"err_snippet\":\"$(tail -c 600 "${ERR}" 2>/dev/null|redact|json_str)\""

# ITER 8: report + notify
[[ -x "${HR_DIR}/hreport.sh" ]] && HARNESS_RUN_DIR="${RUN_DIR}" bash "${HR_DIR}/hreport.sh" "${LABEL}" "${rc}" "${DUR}" "${ANOMALIES[*]:-}" "${RUN_ID}" || true
(( rc==0 )) && notify normal "OK ${LABEL} (${DUR}ms)" || notify critical "FAIL ${LABEL} exit ${rc} -> ${RUN_DIR}"
cat "${OUT}"; cat "${ERR}" >&2
exit "${rc}"
