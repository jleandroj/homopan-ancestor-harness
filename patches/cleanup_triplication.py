#!/usr/bin/env python3
"""cleanup_triplication.py -- P0.3: collapse non-idempotent-patch triplication.

The legacy patch flow (apply_protected_p1_p3.sh, fixed anchors) inserted three
identical copies of several blocks into PROTECTED security files. This script
collapses every run of >=2 identical units back to ONE, idempotently:

  - it matches the EXACT block text, so it cannot touch unrelated code;
  - it uses (unit){2,} -> unit, so re-running it is a clean no-op;
  - it reports per-file how many collapses happened (0 = already clean / no match).

It edits protected files, so a HUMAN must run it (the gate blocks the agent).
After running it, regenerate the gate pass:  bash init.sh
"""
import re
import sys
from pathlib import Path

import os
# ROOT defaults to the real repo; override via $HOMOPAN_CLEANUP_ROOT or a
# positional arg so tests can run against a throwaway copy of the tree.
_root_arg = next((a for a in sys.argv[1:] if not a.startswith("-")), None)
ROOT = Path(os.environ.get("HOMOPAN_CLEANUP_ROOT", _root_arg or
                           Path(__file__).resolve().parent.parent)).resolve()

# (relative path, exact repeated unit incl. trailing newline(s))
TARGETS = [
    # gate_check.sh: 3x  comment(3 lines)+source+blank
    (".claude/gate_check.sh",
     "# ── Extracted command detector (#12) -- single source of truth, fuzzed in\n"
     "# tests/test_cmd_detector_fuzz.sh. Sourced AFTER the inline copy so the module\n"
     "# definitions win; remove the inline copies above once this is in place.\n"
     'source "${SCRIPT_DIR}/cmd_detector.sh"\n\n'),

    # _guard.sh: 3x  comment+max-redirect+blank
    ("scripts/net_wrappers/_guard.sh",
     "  # wget follows redirects by default; pin it so only the vetted host is hit.\n"
     '  [[ "$tool" == "wget" ]] && set -- --max-redirect=0 "$@"\n\n'),

    # bitacora_log.sh: 3x SID/CWD extraction + 4 tag lines
    (".claude/bitacora_log.sh",
     'if [[ -n "${JQ_BIN}" ]]; then\n'
     "  _SID=$(printf '%s' \"${INPUT}\" | \"${JQ_BIN}\" -r '.session_id // empty' 2>/dev/null || true)\n"
     "  _CWD=$(printf '%s' \"${INPUT}\" | \"${JQ_BIN}\" -r '.cwd // empty' 2>/dev/null || true)\n"
     "else\n"
     "  _SID=$(printf '%s' \"${INPUT}\" | grep -o '\"session_id\"[[:space:]]*:[[:space:]]*\"[^\"]*\"' | head -1 | sed 's/.*: *\"//;s/\"$//' || true)\n"
     "  _CWD=$(printf '%s' \"${INPUT}\" | grep -o '\"cwd\"[[:space:]]*:[[:space:]]*\"[^\"]*\"' | head -1 | sed 's/.*: *\"//;s/\"$//' || true)\n"
     "fi\n"
     'RUN_ID_TAG="${HOMOPAN_RUN_ID:-unknown}"\n'
     'AGENT_TAG="${HOMOPAN_AGENT:-${CLAUDE_AGENT:-unknown}}"\n'
     'SESSION_TAG="${_SID:-${HOMOPAN_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}}"\n'
     'CWD_TAG="${_CWD:-${HOMOPAN_CWD:-unknown}}"\n'),

    # bitacora_log.sh: 3x  --arg run_id ... line (appears in two jq calls)
    (".claude/bitacora_log.sh",
     '      --arg run_id "${RUN_ID_TAG}" --arg agent "${AGENT_TAG}" --arg session "${SESSION_TAG}" --arg cwd "${CWD_TAG}" \\\n'),

    # bitacora_log.sh: 3x  bash-pure RUN_ESC/.. line
    (".claude/bitacora_log.sh",
     '  RUN_ESC=$(json_escape "${RUN_ID_TAG}"); AG_ESC=$(json_escape "${AGENT_TAG}"); SE_ESC=$(json_escape "${SESSION_TAG}"); CW_ESC=$(json_escape "${CWD_TAG}")\n'),
]


def main() -> int:
    check = "--check" in sys.argv
    total = 0
    for rel, unit in TARGETS:
        p = ROOT / rel
        if not p.exists():
            print(f"SKIP  {rel}: not found")
            continue
        text = p.read_text()
        pat = re.compile("(?:" + re.escape(unit) + "){2,}")
        n = len(pat.findall(text))
        sig = unit.strip().splitlines()[0][:48]
        if n == 0:
            print(f"OK    {rel}: no run of >=2 for unit <{sig}...>")
            continue
        if check:
            print(f"WOULD-FIX {rel}: {n} duplicated run(s) for <{sig}...>")
        else:
            p.write_text(pat.sub(unit, text))
            print(f"FIXED {rel}: collapsed {n} duplicated run(s) -> 1")
        total += n
    tail = " (dry-run, no writes)" if check else ""
    print(f"\nDone. {total} matched run(s){tail}." + ("" if check else " Now run: bash init.sh"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
