#!/usr/bin/env bash
# add_autoverify_hook.sh -- operator-run: install the Stop hook that runs the
# honesty checks automatically after EVERY agent turn. .claude/settings.json is a
# PROTECTED file (the agent cannot edit it), so YOU run this. Idempotent (uses jq
# to set, not append). After running it:  bash init.sh   (regenerate gate pass).
#
#   bash patches/add_autoverify_hook.sh [path/to/settings.json]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="${1:-${ROOT}/.claude/settings.json}"
[[ -f "${S}" ]] || { echo "no settings.json at ${S}" >&2; exit 1; }
jq=jq; command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }

# Set (not append) the Stop hook -> running twice is a clean no-op (idempotent).
tmp="$(mktemp)"
"${jq}" '.hooks.Stop = [{"matcher":"*","hooks":[{"type":"command","command":"bash scripts/harness/auto_verify.sh"}]}]' \
  < "${S}" > "${tmp}" && mv -f "${tmp}" "${S}"
echo "Stop hook installed in ${S}. Now run:  bash init.sh"
"${jq}" -e '.hooks.Stop[0].hooks[0].command | test("auto_verify")' < "${S}" >/dev/null \
  && echo "verified: auto_verify Stop hook present"
