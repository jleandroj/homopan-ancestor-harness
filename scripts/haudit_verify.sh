#!/usr/bin/env bash
# haudit_verify.sh -- ITER 10: verify the append-only audit log hash chain.
# Each line embeds prev:<first16 of sha256(previous line)>. If any past line was
# edited/removed/reordered, the chain breaks and we report the first bad line.
# Usage: haudit_verify.sh [audit_log]
set -uo pipefail
AUDIT="${1:-${HARNESS_AUDIT_LOG:-${HOME}/.harness_audit.jsonl}}"
[[ -s "${AUDIT}" ]] || { echo "no audit log at ${AUDIT}"; exit 0; }

prev=""; n=0; bad=0
while IFS= read -r line; do
  n=$((n+1))
  exp="${prev:0:16}"
  got="$(sed -E 's/.*"prev":"([^"]*)".*/\1/' <<<"$line")"
  if [[ "$n" -gt 1 && "$got" != "$exp" ]]; then
    echo "CHAIN BREAK at line ${n}: expected prev=${exp} got=${got}"; bad=$((bad+1))
  fi
  prev="$(printf '%s' "$line" | sha256sum | cut -d' ' -f1)"
done < "${AUDIT}"

if (( bad == 0 )); then echo "audit OK: ${n} lines, hash chain intact (${AUDIT})"; exit 0
else echo "audit TAMPERED: ${bad} break(s) in ${n} lines"; exit 1; fi
