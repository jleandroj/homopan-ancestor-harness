#!/usr/bin/env bash
# sandbox_run.sh -- Run a command under bubblewrap with NO network and NO access
# to host secrets by default. This is the REAL isolation boundary; the gate and
# permissions.deny are only defense-in-depth (see SECURITY.md).
#
# Confidentiality: the host root is NOT mounted. Only minimal system dirs
# (/usr /bin /sbin /lib /lib64 /etc, read-only) plus the project + work dir
# (read-write) are visible. $HOME is a throwaway /tmp, and the environment is
# CLEARED (--clearenv) so exported secrets/tokens are not inherited. So
# ~/.ssh, ~/.aws, $GITHUB_TOKEN, etc. are unreachable inside.
#
# Network:
#   default              -> --unshare-net (no egress; loopback only)
#   HOMOPAN_ALLOW_NET=1  -> --share-net   (host net; net_wrappers/ allowlist
#                           is auto-prepended to PATH as defense-in-depth)
#
# Escape hatches (opt-in):
#   HOMOPAN_REQUIRE_SANDBOX=1  fail if bwrap is missing (no unsandboxed fallback)
#   HOMOPAN_PASS_ENV="A B C"   pass these env vars through --clearenv
#   HOMOPAN_EXTRA_BINDS="/p1 /p2"  extra read-write binds (e.g. conda, data dirs
#                                  that out-of-repo symlinks point to)
#
# Usage:  bash scripts/sandbox_run.sh <command> [args...]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${HOMOPAN_WORKDIR:-${ROOT}/work}"
mkdir -p "${WORK_DIR}" 2>/dev/null || true

if (( $# == 0 )); then
  echo "usage: sandbox_run.sh <command> [args...]" >&2
  exit 2
fi

if ! command -v bwrap >/dev/null 2>&1; then
  if [[ "${HOMOPAN_REQUIRE_SANDBOX:-0}" == "1" ]]; then
    echo "FATAL: bubblewrap (bwrap) not found and HOMOPAN_REQUIRE_SANDBOX=1 -> refusing to run unsandboxed." >&2
    exit 3
  fi
  echo "WARN: bwrap not found; running WITHOUT sandbox. Set HOMOPAN_REQUIRE_SANDBOX=1 to forbid this." >&2
  exec "$@"
fi

# ── Network policy ─────────────────────────────────────────────────────────
PATH_IN="/usr/bin:/bin:/usr/sbin:/sbin"
if [[ "${HOMOPAN_ALLOW_NET:-0}" == "1" ]]; then
  NET_ARGS=(--share-net)
  PATH_IN="${ROOT}/scripts/net_wrappers:${PATH_IN}"   # egress allowlist first
  echo "WARN: network ENABLED inside sandbox (HOMOPAN_ALLOW_NET=1); egress allowlist active." >&2
else
  NET_ARGS=(--unshare-net)
fi

# ── Minimal read-only system binds (NO /home, NO /root) ───────────────────
# On merged-/usr systems /bin,/sbin,/lib,/lib64 are symlinks into /usr, so we
# bind /usr (+ /etc) and recreate those symlinks rather than binding them.
SYS_BINDS=(--ro-bind /usr /usr)
[[ -e /etc ]] && SYS_BINDS+=(--ro-bind /etc /etc)
for d in bin sbin lib lib64; do
  if [[ -L "/$d" ]]; then
    SYS_BINDS+=(--symlink "$(readlink "/$d")" "/$d")
  elif [[ -d "/$d" ]]; then
    SYS_BINDS+=(--ro-bind "/$d" "/$d")
  fi
done

# ── Cleared environment (bwrap 0.4.0 lacks --clearenv; use `env -i`) ───────
# Starting from an empty env is what hides exported secrets/tokens.
CLEAN_ENV=(env -i "PATH=${PATH_IN}" "HOME=/tmp" "TERM=${TERM:-xterm}" "LANG=${LANG:-C.UTF-8}")
for v in ${HOMOPAN_PASS_ENV:-}; do
  val="${!v:-}"
  [[ -n "${val}" ]] && CLEAN_ENV+=("$v=${val}")
done

# ── Extra read-write binds (out-of-repo data, conda, etc.) ────────────────
EXTRA_BIND_ARGS=()
for p in ${HOMOPAN_EXTRA_BINDS:-}; do
  [[ -e "$p" ]] && EXTRA_BIND_ARGS+=(--bind "$p" "$p")
done

exec "${CLEAN_ENV[@]}" bwrap \
  "${SYS_BINDS[@]}" \
  --proc /proc --dev /dev --tmpfs /tmp \
  --bind "${ROOT}" "${ROOT}" \
  --bind "${WORK_DIR}" "${WORK_DIR}" \
  "${EXTRA_BIND_ARGS[@]}" \
  "${NET_ARGS[@]}" \
  --unshare-ipc --unshare-uts --unshare-pid \
  --die-with-parent \
  --chdir "${ROOT}" \
  "$@"
