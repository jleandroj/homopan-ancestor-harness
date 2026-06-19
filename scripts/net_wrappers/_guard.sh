#!/usr/bin/env bash
# _guard.sh -- shared egress allowlist check for the curl/wget wrappers.
# Sourced by the wrappers. Put this directory FIRST on PATH (e.g. inside
# sandbox_run with HOMOPAN_ALLOW_NET=1) to force outbound requests through the
# allowlist in egress_allowlist.txt. Default-deny: unknown host -> blocked.
net_guard() {
  local tool="$1"; shift
  local here root allowlist real d
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="$(cd "${here}/../.." && pwd)"
  allowlist="${HOMOPAN_EGRESS_ALLOWLIST:-${root}/egress_allowlist.txt}"

  _host_allowed() {
    local h="$1" e
    [[ -f "$allowlist" ]] || return 1
    while IFS= read -r e; do
      e="${e%%#*}"; e="${e// /}"; [[ -z "$e" ]] && continue
      [[ "$h" == "$e" || "$h" == *."$e" ]] && return 0
    done < "$allowlist"
    return 1
  }

  local a h
  for a in "$@"; do
    case "$a" in
      http://*|https://*|ftp://*|ftps://*)
        h=${a#*://}; h=${h%%[/?]*}; h=${h##*@}; h=${h%%:*}
        if ! _host_allowed "$h"; then
          echo "egress DENY (${tool}): '${h}' not in $(basename "${allowlist}")." >&2
          exit 7
        fi ;;
    esac
  done

  # Resolve the real tool, skipping this wrapper directory.
  IFS=: read -ra _p <<<"$PATH"
  for d in "${_p[@]}"; do
    [[ "$d" == "$here" ]] && continue
    [[ -x "$d/$tool" ]] && { real="$d/$tool"; break; }
  done
  [[ -z "${real:-}" ]] && real="/usr/bin/${tool}"
  exec "$real" "$@"
}
