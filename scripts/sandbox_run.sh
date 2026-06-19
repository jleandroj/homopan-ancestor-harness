#!/usr/bin/env bash
# sandbox_run.sh -- Run a command under bubblewrap with NO network by default.
#
# This is the REAL isolation boundary for the harness. The PreToolUse gate and
# settings.json permissions.deny are DEFENSE-IN-DEPTH (advisory/heuristic), NOT
# a sandbox: glob deny-rules and command parsing are not a security boundary.
# For a "secure/prod" claim, run untrusted work through THIS wrapper.
#
# Network:
#   default              -> --unshare-net (no egress at all; loopback only)
#   HOMOPAN_ALLOW_NET=1  -> --share-net  (host network; use only when needed)
# A true per-host egress *allowlist* needs a filtering proxy or root/iptables
# (no passwordless sudo here); see scripts/net_wrappers/ for the tool-level
# allowlist used when network is shared.
#
# Filesystem: read-only view of /, with the project root + work dir (+ any
# HOMOPAN_EXTRA_BINDS, space-separated) bound read-write.
#
# Usage:  bash scripts/sandbox_run.sh <command> [args...]
#         HOMOPAN_ALLOW_NET=1 bash scripts/sandbox_run.sh ...
#         HOMOPAN_EXTRA_BINDS="/data /mnt/s1" bash scripts/sandbox_run.sh ...
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

# Network policy
if [[ "${HOMOPAN_ALLOW_NET:-0}" == "1" ]]; then
  NET_ARGS=(--share-net)
  echo "WARN: network ENABLED inside sandbox (HOMOPAN_ALLOW_NET=1)." >&2
else
  NET_ARGS=(--unshare-net)
fi

# Extra read-write binds (e.g. data dirs that symlinks point outside the repo)
EXTRA_BIND_ARGS=()
for p in ${HOMOPAN_EXTRA_BINDS:-}; do
  [[ -e "$p" ]] && EXTRA_BIND_ARGS+=(--bind "$p" "$p")
done

exec bwrap \
  --ro-bind / / \
  --dev /dev \
  --proc /proc \
  --tmpfs /tmp \
  --bind "${ROOT}" "${ROOT}" \
  --bind "${WORK_DIR}" "${WORK_DIR}" \
  "${EXTRA_BIND_ARGS[@]}" \
  "${NET_ARGS[@]}" \
  --unshare-ipc --unshare-uts --unshare-pid \
  --die-with-parent \
  --chdir "${ROOT}" \
  "$@"
