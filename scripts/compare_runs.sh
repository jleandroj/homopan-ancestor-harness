#!/usr/bin/env bash
# compare_runs.sh -- rigorously diff two per-run manifests (#5 longitudinal rigor).
#
# Each completed pipeline run writes an immutable manifest at
# qc/manifests/<run_id>.json (see write_run_manifest in config.sh). This tool
# diffs two of them at the leaf-field level and tells you WHICH category changed,
# so a different output hash with identical inputs is correctly read as
# non-determinism (e.g. unseeded Cactus), not as an input change.
#
# Usage: bash scripts/compare_runs.sh <run_id_a> <run_id_b>
#        bash scripts/compare_runs.sh --list          # list available run ids
set -euo pipefail
source "$(dirname "$0")/config.sh"

MANI_DIR="${QC_DIR}/manifests"
JQ="$(command -v jq || true)"
[[ -z "${JQ}" && -x "${HOME}/miniconda3/envs/homopan_ancestor/bin/jq" ]] && JQ="${HOME}/miniconda3/envs/homopan_ancestor/bin/jq"
[[ -n "${JQ}" ]] || die "jq required for compare_runs.sh"

if [[ "${1:-}" == "--list" ]]; then
  echo "Available run manifests in $(sanitize_path "${MANI_DIR}"):"
  ls -1 "${MANI_DIR}"/*.json 2>/dev/null | sed 's|.*/||;s|\.json$||' || echo "  (none yet)"
  exit 0
fi

A="${1:?usage: compare_runs.sh <run_id_a> <run_id_b> (or --list)}"
B="${2:?need two run ids}"
MA="${MANI_DIR}/${A}.json"; MB="${MANI_DIR}/${B}.json"
[[ -f "${MA}" ]] || die "manifest not found: $(sanitize_path "${MA}")"
[[ -f "${MB}" ]] || die "manifest not found: $(sanitize_path "${MB}")"

# Flatten each manifest to sorted "path=value" leaf lines and diff them.
# Read via STDIN so a confined jq (snap) that can't open file paths still works.
_flat() { "${JQ}" -r 'paths(scalars) as $p | "\($p|join("."))=\(getpath($p))"' < "$1" | sort; }

echo "Comparing run manifests:"
echo "  A = ${A}"
echo "  B = ${B}"
echo ""
DIFF="$(diff <(_flat "${MA}") <(_flat "${MB}") | grep -E '^[<>]' || true)"
if [[ -z "${DIFF}" ]]; then
  echo "IDENTICAL -- every manifest field matches (tools, params, inputs, outputs)."
  exit 0
fi
echo "Differing fields ( < = ${A}, > = ${B} ):"
echo "${DIFF}" | sed 's/^/  /'
echo ""
echo "Interpretation:"
echo "  tools.* differ            -> toolchain changed (container/host tool/seed)."
echo "  params.* or inputs.* differ -> different data or parameters."
echo "  inputs.* SAME but outputs.* differ -> NON-DETERMINISM (e.g. unseeded"
echo "       Cactus / Toil parallelism), not an input change."
exit 0
