#!/usr/bin/env bash
# 03_make_seqfiles.sh -- Generate seqfiles for test and full runs
set -euo pipefail
source "$(dirname "$0")/config.sh"

script_banner "03 - Generate Seqfiles"

acquire_step_lock "03_make_seqfiles"
require_done "01_validate_fastas"

# ── Helper: generate seqfile ─────────────────────────────────────────────
generate_seqfile() {
  local outfile="$1"
  local genome_dir="$2"
  local suffix="$3"

  log_info "Writing $(sanitize_path "${outfile}")"

  # Line 1: Newick tree
  echo "${NEWICK_TREE}" > "${outfile}"

  # Lines 2+: species <tab> absolute_path
  for sp in "${SPECIES[@]}"; do
    local fa="${genome_dir}/${sp}${suffix}.fa"
    [[ -f "${fa}" ]] || die "Missing FASTA: $(sanitize_path "${fa}")"
    echo "${sp} ${fa}" >> "${outfile}"
  done

  # Validate: every line after the tree must have exactly 2 fields
  local bad_lines
  bad_lines=$(awk 'NR>1 && NF!=2' "${outfile}" | wc -l)
  if (( bad_lines > 0 )); then
    die "Seqfile has ${bad_lines} malformed lines (expected 2 fields per species)"
  fi

  log_ok "Seqfile: $(wc -l < "${outfile}") lines (1 tree + ${#SPECIES[@]} species)"
}

# ── Full seqfile ──────────────────────────────────────────────────────────
generate_seqfile "${SEQFILE_FULL}" "${GENOMES_DIR}" ""

# ── Test seqfile ──────────────────────────────────────────────────────────
if is_done "02_make_test_fastas"; then
  generate_seqfile "${SEQFILE_TEST}" "${TEST_GENOMES_DIR}" ".test1Mb"
else
  log_warn "Skipping test seqfile (step 02 not done)"
fi

mark_done "03_make_seqfiles"
