#!/usr/bin/env bash
# _guard.sh -- shared egress allowlist check for the curl/wget wrappers.
# Sourced by the wrappers. Put this directory FIRST on PATH (e.g. inside
# sandbox_run with HOMOPAN_ALLOW_NET=1) to force outbound requests through the
# allowlist in egress_allowlist.txt. Default-deny: unknown host -> blocked.
# Inspects: command-line URLs, -K/--config files, and rejects raw IP hosts and
# stdin-fed config (which it cannot pre-inspect).
net_guard() {
  local tool="$1"; shift
  local here root allowlist real d
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="$(cd "${here}/../.." && pwd)"
  allowlist="${HOMOPAN_EGRESS_ALLOWLIST:-${root}/egress_allowlist.txt}"

  _deny() { echo "egress DENY (${tool}): $1" >&2; exit 7; }

  _host_allowed() {
    local h="${1,,}" e                       # hostnames are case-insensitive
    [[ -f "$allowlist" ]] || return 1
    while IFS= read -r e; do
      e="${e%%#*}"; e="${e// /}"; e="${e,,}"; [[ -z "$e" ]] && continue
      [[ "$h" == "$e" || "$h" == *."$e" ]] && return 0
    done < "$allowlist"
    return 1
  }

  _host_of() {   # extract host from a URL token
    local u="$1" h
    h=${u#*://}; h=${h##*@}
    if [[ "$h" == \[*\]* ]]; then h=${h#\[}; h=${h%%\]*}   # [IPv6]
    else h=${h%%[/?]*}; h=${h%%:*}; fi
    printf '%s' "$h"
  }

  _check_host() {   # <host>
    local h="$1"
    [[ -z "$h" ]] && return 0
    if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$h" == *:* ]]; then
      _host_allowed "$h" || _deny "raw IP host '${h}' not in $(basename "${allowlist}")"
      return 0
    fi
    _host_allowed "$h" || _deny "'${h}' not in $(basename "${allowlist}")"
  }

  # 0. Redirect-following defeats pre-validation (target host is unseen).
  local a
  for a in "$@"; do
    case "$a" in
      -L|--location|--location-trusted) _deny "redirect-following (${a}) not allowed: target host cannot be pre-validated" ;;
    esac
  done

  # 1. URLs on the command line
  for a in "$@"; do
    case "$a" in
      http://*|https://*|ftp://*|ftps://*) _check_host "$(_host_of "$a")" ;;
    esac
  done

  # 2. Config files (-K/--config/--config=); deny stdin configs we cannot inspect
  local i argv=("$@") tok cfg u
  for (( i=0; i<${#argv[@]}; i++ )); do
    tok="${argv[$i]}"; cfg=""
    case "$tok" in
      -K|--config) cfg="${argv[$((i+1))]:-}" ;;
      --config=*)  cfg="${tok#--config=}" ;;
      *) continue ;;
    esac
    [[ "$cfg" == "-" ]] && _deny "config from stdin (${tok} -) cannot be inspected"
    [[ -f "$cfg" ]] || continue
    for u in $(grep -oE '(https?|ftps?)://[^[:space:]"'"'"']+' "$cfg" 2>/dev/null); do
      _check_host "$(_host_of "$u")"
    done
    if grep -qiE '^[[:space:]]*url[[:space:]]*=' "$cfg" 2>/dev/null \
       && ! grep -qiE '(https?|ftps?)://' "$cfg" 2>/dev/null; then
      _deny "unverifiable scheme-less URL in config '${cfg}'"
    fi
  done

  # wget follows redirects by default; pin it so only the vetted host is hit.
  [[ "$tool" == "wget" ]] && set -- --max-redirect=0 "$@"

  # Resolve the real tool, skipping this wrapper directory.
  IFS=: read -ra _p <<<"$PATH"
  for d in "${_p[@]}"; do
    [[ "$d" == "$here" ]] && continue
    [[ -x "$d/$tool" ]] && { real="$d/$tool"; break; }
  done
  [[ -z "${real:-}" ]] && real="/usr/bin/${tool}"
  exec "$real" "$@"
}
