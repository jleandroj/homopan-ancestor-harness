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

# Flatten the DETERMINISTIC repro{} block (NOT meta) to sorted "path=value"
# leaf lines: meta (run_id, timestamp, host, llm) is expected to differ between
# any two runs and must not mask the verdict. Read via STDIN (snap-jq safe).
_flat() { "${JQ}" -r '(.repro // {}) | paths(scalars) as $p | "\($p|join("."))=\(getpath($p))"' < "$1" | sort; }
_rsha() { "${JQ}" -r '.repro_sha256 // "none"' < "$1"; }

echo "Comparing run manifests:"
echo "  A = ${A}"
echo "  B = ${B}"
echo ""
# Headline verdict: the repro_sha256 (hash of the canonical repro{} block).
RA="$(_rsha "${MA}")"; RB="$(_rsha "${MB}")"
echo "repro_sha256:  A=${RA:0:16}...  B=${RB:0:16}..."
if [[ "${RA}" == "${RB}" && "${RA}" != "none" ]]; then
  echo "VERDICT: REPRODUCIBLE -- identical repro block (same inputs, params, toolchain, outputs)."
  echo "         (Only meta differs: run_id/timestamp/host/llm -- expected, non-determining.)"
  exit 0
fi
echo ""
echo "Differing repro fields ( < = ${A}, > = ${B} ):"
DIFF="$(diff <(_flat "${MA}") <(_flat "${MB}") | grep -E '^[<>]' || true)"
echo "${DIFF:-  (repro leaves equal but repro_sha256 differs -- check schema/encoding)}" | sed 's/^/  /'
echo ""
echo "Interpretation:"
echo "  inputs.* / newick / *_seed differ -> different DATA or PARAMETERS."
echo "  sif_sha256 / cactus / samtools differ -> TOOLCHAIN changed."
echo "  inputs.* SAME but outputs.* differ -> NON-DETERMINISM (e.g. unseeded"
echo "       Cactus / Toil parallelism), NOT an input change."
exit 1
