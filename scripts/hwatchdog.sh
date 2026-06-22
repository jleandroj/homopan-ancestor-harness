#!/usr/bin/env bash
# hwatchdog.sh -- ITER 6: standalone watchdog + kill-switch control.
# Commands:
#   hwatchdog.sh kill          arm the kill-switch (refuse/stop harness_run work)
#   hwatchdog.sh unkill        clear it
#   hwatchdog.sh status        show kill-switch + live runs
#   hwatchdog.sh reap <secs>   kill any harness_run child older than <secs>
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HSTATE="${ROOT}/.harness"; KILL="${HSTATE}/KILL"; mkdir -p "${HSTATE}" 2>/dev/null || true

case "${1:-status}" in
  kill)   touch "${KILL}"; echo "KILL-SWITCH ARMADO (${KILL}). harness_run rechazará/cortará trabajo."
          command -v notify-send >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]] && notify-send -u critical "harness" "KILL-SWITCH armado" || true ;;
  unkill) rm -f "${KILL}"; echo "kill-switch limpiado." ;;
  status) [[ -f "${KILL}" ]] && echo "KILL-SWITCH: ARMADO" || echo "kill-switch: off"
          echo "runs recientes:"; ls -1t "${HSTATE}/runs" 2>/dev/null | head -5 ;;
  reap)   secs="${2:-7200}"; now=$(date +%s); n=0
          for d in "${HSTATE}/runs"/*; do
            [[ -d "$d" ]] || continue
            mt=$(stat -c %Y "$d" 2>/dev/null || echo "$now")
            (( now - mt > secs )) || continue
            # best-effort: nothing to kill if already done; report stale
            n=$((n+1))
          done
          echo "reap: ${n} run dir(s) older than ${secs}s (inspección; el kill real lo hace harness_run vía KILL)" ;;
  *) echo "usage: hwatchdog.sh {kill|unkill|status|reap <secs>}" >&2; exit 2 ;;
esac
