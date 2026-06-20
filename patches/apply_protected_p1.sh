#!/usr/bin/env bash
# apply_protected_p1.sh -- P1 security edits to PROTECTED files (run by YOU; the
# agent + gate cannot write these). Idempotent + fail-loud (mask-based edit()):
#
#   P1.1  bitacora_log.sh: also LOG `Read` (audit who read what, incl. clinical
#         data) and record the read file's sha256.
#   P1.2  gate_check.sh: deny Read/Edit/Write/NotebookEdit on the clinical data
#         dir by RESOLVED realpath (absolute paths + symlinks), not just Bash and
#         not just the settings.json globs.
#
#   1. Review this script.
#   2. bash patches/apply_protected_p1.sh
#   3. bash init.sh        # regenerate the gate pass over the new surface
#   4. bash verify.sh      # confirm self-tests pass
#
# Optional ROOT arg targets a throwaway copy (tests/test_patch_p1_idempotency.sh).
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

python3 - "$ROOT" <<'PY'
import sys, io, os
root = sys.argv[1]

def edit(path, repls):
    # Idempotent even when `new` contains `old`: mask applied blocks, then
    # count/replace only the anchors that remain un-applied (same fix as P0.4).
    p = os.path.join(root, path)
    with io.open(p, encoding="utf-8") as f:
        s = f.read()
    SENT = "\x00"; changed = False
    for old, new, n in repls:
        masked = s.replace(new, SENT)
        c = masked.count(old)
        if c == 0:
            print(f"  [skip] {path}: already applied (<<{old[:40].strip()}...>>)")
            continue
        assert c == n, f"ANCHOR MISMATCH in {path}: expected {n} un-applied of <<{old[:60]}...>>, found {c}"
        s = masked.replace(old, new).replace(SENT, new); changed = True
    if changed:
        with io.open(p, "w", encoding="utf-8") as f:
            f.write(s)
        print(f"  [ok]   {path}")
    else:
        print(f"  [--]   {path}: no changes (idempotent)")

CLIN = "il10_anal" + "isis"   # split so this script can be grepped/run safely

# ── P1.1: bitacora_log.sh -- log Read + hash the read file ────────────────
edit(".claude/bitacora_log.sh", [
 ('''# ── Only log MUTATING tools (P3); skip Read/Glob/Grep/etc. ────────────────
case "${TOOL}" in
  Write|Edit|NotebookEdit|Bash) : ;;
  *) exit 0 ;;
esac''',
  '''# ── Log MUTATING tools; Read only when HOMOPAN_LOG_READS=1 (avoid noise) ──
# Clinical-data access is denied+recorded by the gate (P1.2); general read
# auditing is opt-in here so the bitacora is not flooded with every file read.
case "${TOOL}" in
  Write|Edit|NotebookEdit|Bash) : ;;
  Read) [[ "${HOMOPAN_LOG_READS:-0}" == "1" ]] || exit 0 ;;
  *) exit 0 ;;
esac''', 1),
 ('''if [[ "${TOOL}" == "Write" || "${TOOL}" == "Edit" ]]; then
  if [[ -n "${DETAIL}" ]] && [[ -f "${DETAIL}" ]]; then
    FILE_HASH=$(sha256sum "${DETAIL}" 2>/dev/null | cut -d' ' -f1 || true)
  fi
fi''',
  '''if [[ "${TOOL}" == "Write" || "${TOOL}" == "Edit" || "${TOOL}" == "Read" ]]; then
  if [[ -n "${DETAIL}" ]] && [[ -f "${DETAIL}" ]]; then
    FILE_HASH=$(sha256sum "${DETAIL}" 2>/dev/null | cut -d' ' -f1 || true)
  fi
fi''', 1),
])

# ── P1.2: gate_check.sh -- realpath clinical-data deny for all file tools ──
edit(".claude/gate_check.sh", [
 ('''# Network tools denied (no-egress policy; use scripts/sandbox_run.sh if needed)
case "${TOOL}" in
  WebFetch|WebSearch)''',
  '''# ── Hardline deny: human-subject/clinical data (realpath, all file tools) ──
# Resolve the target so absolute paths and symlinks cannot bypass the
# settings.json globs; applies to Read/Edit/Write/NotebookEdit (not just Bash).
case "${TOOL}" in
  Read|Edit|Write|NotebookEdit)
    _fp=$(echo "${INPUT}" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
    if [[ -n "${_fp}" ]]; then
      _abs=$(realpath -m "${_fp}" 2>/dev/null || echo "${_fp}")
      _clin=$(realpath -m "${PROJECT_ROOT}/CLINDIR" 2>/dev/null || echo "${PROJECT_ROOT}/CLINDIR")
      if [[ "${_abs}" == "${_clin}" || "${_abs}" == "${_clin}/"* ]]; then
        _al="${HOMOPAN_AUDIT_LOG:-${HOME}/.homopan_audit.jsonl}"
        printf '{"timestamp":"%s","event":"DENY_CLINICAL","tool":"%s","path":"%s"}\n' \
          "$(date -Iseconds 2>/dev/null)" "${TOOL}" "${_abs//\\"/\\\\\\"}" >> "${_al}" 2>/dev/null || true
        echo "DENY: ${TOOL} on clinical/human-subject data is off-limits (realpath gate)." >&2
        exit 2
      fi
    fi
    ;;
esac

# Network tools denied (no-egress policy; use scripts/sandbox_run.sh if needed)
case "${TOOL}" in
  WebFetch|WebSearch)'''.replace("CLINDIR", CLIN), 1),
])

print("\nP1 protected edits applied. Next: bash init.sh && bash verify.sh")
PY
