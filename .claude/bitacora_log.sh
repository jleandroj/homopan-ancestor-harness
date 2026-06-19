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

# ── Sanitize: redact HOME and PROJECT_ROOT from logged content ────────────
sanitize() {
  local s="$1"
  s="${s//${HOME}/\~}"
  s="${s//${PROJECT_ROOT}/\$PROJECT}"
  echo "${s}"
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

DETAIL_SAFE=$(sanitize "${DETAIL}")

# ── File hash for Write/Edit (audit trail of what changed) ─────────────────
FILE_HASH=""
if [[ "${TOOL}" == "Write" || "${TOOL}" == "Edit" ]]; then
  if [[ -n "${DETAIL}" ]] && [[ -f "${DETAIL}" ]]; then
    FILE_HASH=$(sha256sum "${DETAIL}" 2>/dev/null | cut -d' ' -f1 || true)
  fi
fi

# ── Write log entry ───────────────────────────────────────────────────────
if [[ -n "${JQ_BIN}" ]]; then
  # -c = compact output (one JSON object per line, required for JSONL format)
  if [[ -n "${FILE_HASH}" ]]; then
    "${JQ_BIN}" -cn \
      --arg ts "${TIMESTAMP}" \
      --arg tool "${TOOL}" \
      --arg detail "${DETAIL_SAFE}" \
      --arg sha256_after "${FILE_HASH}" \
      '{timestamp: $ts, tool: $tool, detail: $detail, sha256_after: $sha256_after}' \
      >> "${LOGFILE}" 2>/dev/null || true
  else
    "${JQ_BIN}" -cn \
      --arg ts "${TIMESTAMP}" \
      --arg tool "${TOOL}" \
      --arg detail "${DETAIL_SAFE}" \
      '{timestamp: $ts, tool: $tool, detail: $detail}' \
      >> "${LOGFILE}" 2>/dev/null || true
  fi
else
  # bash-pure JSON output
  TS_ESC=$(json_escape "${TIMESTAMP}")
  TOOL_ESC=$(json_escape "${TOOL}")
  DETAIL_ESC=$(json_escape "${DETAIL_SAFE}")
  if [[ -n "${FILE_HASH}" ]]; then
    HASH_ESC=$(json_escape "${FILE_HASH}")
    printf '{"timestamp":"%s","tool":"%s","detail":"%s","sha256_after":"%s"}\n' \
      "${TS_ESC}" "${TOOL_ESC}" "${DETAIL_ESC}" "${HASH_ESC}" \
      >> "${LOGFILE}" 2>/dev/null || true
  else
    printf '{"timestamp":"%s","tool":"%s","detail":"%s"}\n' \
      "${TS_ESC}" "${TOOL_ESC}" "${DETAIL_ESC}" \
      >> "${LOGFILE}" 2>/dev/null || true
  fi
fi

exit 0
