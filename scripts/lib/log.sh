#!/usr/bin/env bash
# lib/log.sh -- colors, run-tagged logging, die, and path sanitization.
# Sourced by scripts/config.sh (P2.1 modularization). Functions resolve config
# vars (RUN_ID, HOME) at CALL time, so this can be sourced as soon as RUN_ID is
# set. Logs go to STDERR so command-substitution captures (hal2fasta/halStats)
# are never contaminated.

# ── Colors ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────
# Every line carries the run id (and agent/session when the env provides them)
# so interleaved output from concurrent or resumed runs is attributable (#10).
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_AGENT_TAG="${HOMOPAN_AGENT:-${CLAUDE_AGENT:-}}"
_SESSION_TAG="${HOMOPAN_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
_logtag() {
  printf '%s' "${RUN_ID}"
  [[ -n "${_AGENT_TAG}" ]]   && printf '/%s' "${_AGENT_TAG}"
  [[ -n "${_SESSION_TAG}" ]] && printf '/%s' "${_SESSION_TAG}"
}

log_info()  { echo -e "${BLUE}[$(_ts)]${NC}[$(_logtag)] ${BOLD}INFO${NC}  $*" >&2; }
log_ok()    { echo -e "${GREEN}[$(_ts)]${NC}[$(_logtag)] ${GREEN}OK${NC}    $*" >&2; }
log_warn()  { echo -e "${YELLOW}[$(_ts)]${NC}[$(_logtag)] ${YELLOW}WARN${NC}  $*" >&2; }
log_error() { echo -e "${RED}[$(_ts)]${NC}[$(_logtag)] ${RED}ERROR${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[$(_ts)]${NC}[$(_logtag)] ${BOLD}STEP${NC}  $*" >&2; }

die() { log_error "$@"; exit 1; }

# ── Sanitize paths for logging (redact $HOME) ────────────────────────────
sanitize_path() {
  local p="$1"
  echo "${p//${HOME}/\~}"
}
