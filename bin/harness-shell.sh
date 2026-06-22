#!/usr/bin/env bash
# harness-shell.sh -- ITER 4 (containment): start the agent session INSIDE
# bubblewrap, so the agent process has NO host $HOME (no ~/.ssh, ~/.aws, no
# stray secrets), a read-only system, and only the project + work dirs writable.
#
# Network IS shared (the agent needs the LLM API to function); per-command
# egress/resource containment is enforced separately by scripts/harness_run.sh
# (no-net sandbox + ulimits + timeout per command). Only the API key is passed
# through the cleared environment -- nothing else.
#
# Usage:  bin/harness-shell.sh [agent-cmd ...]      (default: 'claude')
# Env:    HARNESS_AGENT_CMD (override the agent binary), ANTHROPIC_API_KEY.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${HOMEPAN_WORKDIR:-${ROOT}/work}"; mkdir -p "${WORK}" 2>/dev/null || true
BWRAP="${HOMEPAN_BWRAP_BIN:-bwrap}"
AGENT=( "${@:-${HARNESS_AGENT_CMD:-claude}}" )

command -v "${BWRAP}" >/dev/null 2>&1 || { echo "FATAL: bwrap no encontrado; instalá bubblewrap." >&2; exit 3; }

# minimal read-only system (merged-/usr aware) + only the dirs we need
SYS=(--ro-bind /usr /usr)
for e in /etc/ld.so.cache /etc/ld.so.conf /etc/ld.so.conf.d /etc/alternatives \
         /etc/ssl /etc/pki /etc/ca-certificates /etc/ca-certificates.conf \
         /etc/nsswitch.conf /etc/passwd /etc/group /etc/resolv.conf /etc/hosts /etc/localtime; do
  [[ -e "$e" ]] && SYS+=(--ro-bind "$e" "$e")
done
for d in bin sbin lib lib64; do
  if [[ -L "/$d" ]]; then SYS+=(--symlink "$(readlink "/$d")" "/$d")
  elif [[ -d "/$d" ]]; then SYS+=(--ro-bind "/$d" "/$d"); fi
done

# conda (the agent needs it for tools) bound read-only if present
EXTRA=()
[[ -d "${HOME}/miniconda3" ]] && EXTRA+=(--ro-bind "${HOME}/miniconda3" "${HOME}/miniconda3")

# cleared env: pass ONLY what the agent needs; NO secrets except the API key.
CLEAN=(env -i "PATH=${PATH}" "HOME=/tmp/agent-home" "TERM=${TERM:-xterm}" "LANG=${LANG:-C.UTF-8}" "DISPLAY=${DISPLAY:-}")
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && CLEAN+=("ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")

echo "[harness-shell] sesión del agente en bwrap: root RO, sin \$HOME real, proyecto RW, red compartida (solo API)." >&2
exec "${CLEAN[@]}" "${BWRAP}" \
  "${SYS[@]}" "${EXTRA[@]}" \
  --proc /proc --dev /dev --tmpfs /tmp \
  --bind "${ROOT}" "${ROOT}" --bind "${WORK}" "${WORK}" \
  --share-net --unshare-ipc --unshare-uts --die-with-parent \
  --chdir "${ROOT}" \
  "${AGENT[@]}"
