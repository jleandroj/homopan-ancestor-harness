#!/usr/bin/env bash
# cmd_detector.sh -- isolated detector for dangerous Bash commands.
#
# Extracted from gate_check.sh (#12) so the heuristic command parsing can be
# unit-tested and FUZZED in isolation (tests/test_cmd_detector_fuzz.sh) without
# standing up the whole hook. gate_check.sh sources this file and calls the two
# functions; the logic here is the single source of truth.
#
# IMPORTANT (honesty): this is heuristic, defense-in-depth parsing, NOT a
# security boundary. Obfuscation it doesn't recognize can slip through; the
# real containment boundary is scripts/sandbox_run.sh (see SECURITY.md). The
# fuzz suite exists to raise the cost of an evasion, not to prove correctness.
#
# Functions (both return 0 = "flagged / should DENY", 1 = "clean"):
#   bash_writes_protected <cmd>   command tries to modify a protected file / pass
#   bash_is_obfuscated   <cmd>    decode|exec, fetch|exec, or non-conda eval
#
# CLI (for fuzzing / manual checks); exit 0 = flagged, 1 = clean:
#   cmd_detector.sh writes '<cmd>'
#   cmd_detector.sh obfusc '<cmd>'
#   cmd_detector.sh any    '<cmd>'      # either detector fires
# The command may also be supplied on stdin if omitted as an argument.

# ── Protected-file write / gate-pass-forge detection ──────────────────────
bash_writes_protected() {
  local c="$1"
  # Protected = contract surface + the REAL boundary scripts (sandbox/egress).
  local prot='(CLAUDE\.md|agents\.md|gate_check\.sh|bitacora_log\.sh|settings\.json|init\.sh|\.gate_pass|sandbox_run\.sh|_guard\.sh|egress_allowlist\.txt|cmd_detector\.sh)'

  # 1. Never allow the agent to touch the gate pass via Bash.
  grep -Eq '\.gate_pass' <<<"$c" && return 0

  # Normalized copy: strip quotes and backslashes so >'CLAUDE.md', >"CLAUDE.md"
  # and >C\LAUDE.md cannot hide the target from the patterns below (fuzz P1).
  local n s
  n=$(printf '%s' "$c" | tr -d "\"'" | tr -d '\\')

  for s in "$c" "$n"; do
    # 2. Redirection ( > or >> , optional fd / path prefix) into a protected file.
    grep -Eq '(^|[^0-9])[0-9]*>>?[[:space:]]*([^[:space:]"'"'"';|&]*/)?'"$prot" <<<"$s" && return 0
    # 3. In-place / copy / move / truncate utilities targeting a protected file.
    grep -Eq '(^|[[:space:];&|(])(sed[[:space:]]+-i|perl[[:space:]]+-[A-Za-z]*i|awk[[:space:]]+-i|tee([[:space:]]+-a)?|cp|mv|dd|install|truncate|ln|chmod|chown|rm|shred)([[:space:]]|=).*'"$prot" <<<"$s" && return 0
  done

  # 4. Interpreter writing to a protected file (python/perl/ruby/node/php).
  if grep -Eq '(python|perl|ruby|node|php)' <<<"$c" \
     && grep -Eq "$prot" <<<"$n" \
     && grep -Eq "(open\(|['\"]w['\"]|>>?|writeFile|O_WRONLY|O_CREAT)" <<<"$c"; then
    return 0
  fi

  return 1
}

# ── Obfuscated / remote execution detection ───────────────────────────────
bash_is_obfuscated() {
  local c="$1"
  # base64/xxd/openssl/gpg decoded then piped to a shell
  grep -Eq '(base64|xxd|openssl[[:space:]]+enc|gpg)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh\b' <<<"$c" && return 0
  # remote fetch piped to a shell (egress + exec)
  grep -Eq '(curl|wget|fetch)\b[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh\b' <<<"$c" && return 0
  # eval: deny EXCEPT the standard conda/mamba activation hook
  if grep -Eq '(^|[[:space:];&|(])eval([[:space:]]|$)' <<<"$c"; then
    grep -Eq 'eval[[:space:]]+"?\$\([^)]*\b(conda|mamba|micromamba)\b[^)]*shell' <<<"$c" || return 0
  fi
  return 1
}

# ── CLI dispatch (only when executed directly, not when sourced) ──────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _mode="${1:-any}"
  if [[ $# -ge 2 ]]; then _cmd="$2"; else _cmd="$(cat)"; fi
  case "${_mode}" in
    writes) bash_writes_protected "${_cmd}" && exit 0 || exit 1 ;;
    obfusc) bash_is_obfuscated   "${_cmd}" && exit 0 || exit 1 ;;
    any)    { bash_writes_protected "${_cmd}" || bash_is_obfuscated "${_cmd}"; } && exit 0 || exit 1 ;;
    *)      echo "usage: cmd_detector.sh {writes|obfusc|any} '<cmd>'" >&2; exit 2 ;;
  esac
fi
