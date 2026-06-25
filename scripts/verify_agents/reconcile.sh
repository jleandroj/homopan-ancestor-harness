#!/usr/bin/env bash
# reconcile.sh -- compare a STATED value (e.g. what the AI told you in chat) to
# what the on-disk result file actually contains. Closes lie-vector #2: prose is
# never trusted; the file is recomputed and compared.
#
#   reconcile.sh <file> <expected> [grep_pattern]
#     no pattern   -> actual = number of non-empty, non-comment lines
#     grep_pattern -> actual = number of lines matching the (extended-regex) pattern
#
# Exit 0 + status MATCH if expected==actual; exit 1 + status MISMATCH otherwise.
# Prints a JSON verdict. Example:
#   reconcile.sh de_summary.tsv 500 $'\tsignificant'   # "the AI said 500 significant genes"
set -uo pipefail
file="${1:?usage: reconcile.sh <file> <expected> [grep_pattern]}"
expected="${2:?expected value}"
pattern="${3:-}"
[[ -f "${file}" ]] || { printf '{"status":"NO_FILE","file":"%s"}\n' "${file}"; exit 2; }
if [[ -n "${pattern}" ]]; then
  actual="$(grep -Ec -- "${pattern}" "${file}" 2>/dev/null || echo 0)"
  how="lines matching /${pattern}/"
else
  actual="$(grep -cvE '^\s*(#|$)' "${file}" 2>/dev/null || echo 0)"
  how="non-empty non-comment lines"
fi
status="MISMATCH"; [[ "${expected}" == "${actual}" ]] && status="MATCH"
jq=jq; command -v jq >/dev/null 2>&1 || jq=cat
printf '{"file":"%s","how":"%s","stated":"%s","actual":"%s","status":"%s"}\n' \
  "${file}" "${how}" "${expected}" "${actual}" "${status}"
[[ "${status}" == "MATCH" ]]
