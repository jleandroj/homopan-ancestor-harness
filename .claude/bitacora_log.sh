#!/usr/bin/env bash
# bitacora_log.sh -- PostToolUse logger with path redaction
# Logs tool calls to logs/bitacora.jsonl, redacting sensitive paths.
# Fail-open: never blocks operations even if logging fails.
# Works with or without jq (bash-pure fallback).
set -euo pipefail

# ── Derive project root ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOGFILE="${PROJECT_ROOT}/logs/bitacora.jsonl"
mkdir -p "$(dirname "${LOGFILE}")"

# ── Find jq (optional -- bash fallback if missing) ──────────────────────
JQ_BIN=""
if command -v jq &>/dev/null; then
  JQ_BIN="jq"
else
  for candidate in \
    "${HOME}/miniconda3/envs/homopan_ancestor/bin/jq" \
    "${HOME}/miniconda3/bin/jq" \
    "${HOME}/anaconda3/envs/homopan_ancestor/bin/jq" \
    "/usr/bin/jq"; do
    if [[ -x "${candidate}" ]]; then
      JQ_BIN="${candidate}"
      break
    fi
  done
fi

# ── Parse hook input ─────────────────────────────────────────────────────
INPUT=$(cat)
TIMESTAMP=$(date -Iseconds)

# ── Sanitize: redact HOME/PROJECT_ROOT paths AND secret-shaped tokens ─────
# Token redaction is best-effort (covers common cloud/VCS/API/JWT formats and
# key=value secrets). File content hashes are computed separately and are not
# passed through here, so sha256_after is never clobbered.
sanitize() {
  local s="$1"
  s="${s//${HOME}/\~}"
  s="${s//${PROJECT_ROOT}/\$PROJECT}"
  s=$(printf '%s' "$s" | sed -E \
    -e 's/AKIA[0-9A-Z]{16}/<REDACTED_AWS_KEY>/g' \
    -e 's/gh[pousr]_[A-Za-z0-9]{20,}/<REDACTED_TOKEN>/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/<REDACTED_TOKEN>/g' \
    -e 's/xox[baprs]-[A-Za-z0-9-]{8,}/<REDACTED_SLACK_TOKEN>/g' \
    -e 's/sk-[A-Za-z0-9]{20,}/<REDACTED_API_KEY>/g' \
    -e 's/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}/<REDACTED_JWT>/g' \
    -e 's/AIza[0-9A-Za-z_-]{35}/<REDACTED_GCP_KEY>/g' \
    -e 's/-----BEGIN[A-Z ]*PRIVATE KEY-----/<REDACTED_PRIVATE_KEY>/g' \
    -e 's/([Aa]uthorization:[[:space:]]*[Bb]earer[[:space:]]+)[A-Za-z0-9._-]+/\1<REDACTED>/g' \
    -e 's/(([Pp]assword|[Pp]asswd|[Tt]oken|[Ss]ecret|[Aa]pi[_-]?[Kk]ey)[[:space:]]*[=:][[:space:]]*)[^[:space:]"'"'"'\&]+/\1<REDACTED>/g' \
    2>/dev/null)
  printf '%s' "$s"
}

# ── Escape string for JSON (bash-pure, no jq needed) ─────────────────────
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  echo "${s}"
}

# ── Extract fields: try jq first, fallback to grep/sed ────────────────────
if [[ -n "${JQ_BIN}" ]]; then
  TOOL=$(echo "${INPUT}" | "${JQ_BIN}" -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")
  case "${TOOL}" in
    Bash)
      DETAIL=$(echo "${INPUT}" | "${JQ_BIN}" -r '.tool_input.command // ""' 2>/dev/null || echo "")
      ;;
    Write|Edit|Read)
      DETAIL=$(echo "${INPUT}" | "${JQ_BIN}" -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
      ;;
    *)
      DETAIL=""
      ;;
  esac
else
  # bash-pure fallback: extract tool_name with grep/sed
  TOOL=$(echo "${INPUT}" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//' || echo "unknown")
  [[ -z "${TOOL}" ]] && TOOL="unknown"
  case "${TOOL}" in
    Bash)
      DETAIL=$(echo "${INPUT}" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//' || echo "")
      ;;
    Write|Edit|Read)
      DETAIL=$(echo "${INPUT}" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//' || echo "")
      ;;
    *)
      DETAIL=""
      ;;
  esac
fi

# ── Only log MUTATING tools (P3); skip Read/Glob/Grep/etc. ────────────────
case "${TOOL}" in
  Write|Edit|NotebookEdit|Bash) : ;;
  *) exit 0 ;;
esac

DETAIL_SAFE=$(sanitize "${DETAIL}")

# ── Outcome (success/error) from the tool response ────────────────────────
if [[ -n "${JQ_BIN}" ]]; then
  OUTCOME=$(echo "${INPUT}" | "${JQ_BIN}" -r \
    'if (.tool_response.is_error // false) or ((.tool_response.error // null) != null) then "error" else "ok" end' \
    2>/dev/null || echo "unknown")
  [[ -z "${OUTCOME}" ]] && OUTCOME="unknown"
else
  # bash-pure fallback cannot parse nested tool_response reliably
  if grep -q '"is_error"[[:space:]]*:[[:space:]]*true' <<<"${INPUT}"; then
    OUTCOME="error"
  else
    OUTCOME="unknown"
  fi
fi

# ── File hash for Write/Edit (audit trail of what changed) ─────────────────
FILE_HASH=""
if [[ "${TOOL}" == "Write" || "${TOOL}" == "Edit" ]]; then
  if [[ -n "${DETAIL}" ]] && [[ -f "${DETAIL}" ]]; then
    FILE_HASH=$(sha256sum "${DETAIL}" 2>/dev/null | cut -d' ' -f1 || true)
  fi
fi

# ── Build the JSON line ───────────────────────────────────────────────────
if [[ -n "${JQ_BIN}" ]]; then
  # -c = compact output (one JSON object per line, required for JSONL format)
  if [[ -n "${FILE_HASH}" ]]; then
    LINE=$("${JQ_BIN}" -cn \
      --arg ts "${TIMESTAMP}" --arg tool "${TOOL}" --arg detail "${DETAIL_SAFE}" \
      --arg outcome "${OUTCOME}" --arg sha256_after "${FILE_HASH}" \
      '{timestamp: $ts, tool: $tool, detail: $detail, outcome: $outcome, sha256_after: $sha256_after}' \
      2>/dev/null || true)
  else
    LINE=$("${JQ_BIN}" -cn \
      --arg ts "${TIMESTAMP}" --arg tool "${TOOL}" --arg detail "${DETAIL_SAFE}" \
      --arg outcome "${OUTCOME}" \
      '{timestamp: $ts, tool: $tool, detail: $detail, outcome: $outcome}' \
      2>/dev/null || true)
  fi
else
  # bash-pure JSON output
  TS_ESC=$(json_escape "${TIMESTAMP}")
  TOOL_ESC=$(json_escape "${TOOL}")
  DETAIL_ESC=$(json_escape "${DETAIL_SAFE}")
  OUTCOME_ESC=$(json_escape "${OUTCOME}")
  if [[ -n "${FILE_HASH}" ]]; then
    HASH_ESC=$(json_escape "${FILE_HASH}")
    LINE=$(printf '{"timestamp":"%s","tool":"%s","detail":"%s","outcome":"%s","sha256_after":"%s"}' \
      "${TS_ESC}" "${TOOL_ESC}" "${DETAIL_ESC}" "${OUTCOME_ESC}" "${HASH_ESC}")
  else
    LINE=$(printf '{"timestamp":"%s","tool":"%s","detail":"%s","outcome":"%s"}' \
      "${TS_ESC}" "${TOOL_ESC}" "${DETAIL_ESC}" "${OUTCOME_ESC}")
  fi
fi

# ── Rotate when large; keep BITACORA_KEEP generations (retention, P3) ──────
LOG_MAX_BYTES=${BITACORA_MAX_BYTES:-5242880}   # 5 MB
LOG_KEEP=${BITACORA_KEEP:-3}
if [[ -f "${LOGFILE}" ]]; then
  _sz=$(stat -c %s "${LOGFILE}" 2>/dev/null || wc -c < "${LOGFILE}" 2>/dev/null || echo 0)
  if (( _sz > LOG_MAX_BYTES )); then
    rm -f "${LOGFILE}.${LOG_KEEP}" 2>/dev/null || true
    for (( i=LOG_KEEP-1; i>=1; i-- )); do
      [[ -f "${LOGFILE}.${i}" ]] && mv -f "${LOGFILE}.${i}" "${LOGFILE}.$((i+1))" 2>/dev/null || true
    done
    mv -f "${LOGFILE}" "${LOGFILE}.1" 2>/dev/null || true
  fi
fi

# ── Append atomically (flock avoids interleaved lines under concurrency) ───
if [[ -n "${LINE}" ]]; then
  if command -v flock &>/dev/null; then
    ( flock 9; printf '%s\n' "${LINE}" >> "${LOGFILE}" ) 9>"${LOGFILE}.lock" 2>/dev/null || true
  else
    printf '%s\n' "${LINE}" >> "${LOGFILE}" 2>/dev/null || true
  fi
fi

exit 0
