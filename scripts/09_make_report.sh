#!/usr/bin/env bash
# 09_make_report.sh -- Generate final Markdown report from actual outputs
set -euo pipefail
source "$(dirname "$0")/config.sh"

script_banner "09 - Generate Report"

REPORT="${RESULTS_REPORTS}/HomoPan_ancestor_report.md"

# ── Assertive preconditions: never emit a "report" on partial output ──────
acquire_step_lock "09_make_report"
require_done "08_extract_ancestors"
assert_file_nonempty "${HAL_FULL}" "Full HAL"
for anc in "${ANCESTOR_NODES[@]}"; do
  assert_file_nonempty "${RESULTS_ANCESTORS}/${anc}.fa" "ancestor ${anc}.fa"
done

{
  echo "# HomoPan Ancestor Reconstruction Report"
  echo ""
  echo "Generated: $(date -Iseconds)"
  echo "Run ID: ${RUN_ID}"
  echo "Host: $(hostname)"
  echo "Status: COMPLETE (full HAL + all ${#ANCESTOR_NODES[@]} ancestors present)"
  echo ""

  # ── Project question ──────────────────────────────────────────────────
  echo "## Project Question"
  echo ""
  echo "Reconstruct the Homo-Pan common ancestor genome using progressive"
  echo "Cactus whole-genome alignment of 5 primate species."
  echo ""

  # ── Species ────────────────────────────────────────────────────────────
  echo "## Species Used"
  echo ""
  echo "| Species | Accession |"
  echo "|---------|-----------|"
  if [[ -s "${PROJECT_ROOT}/accessions.tsv" ]]; then
    # Validate provenance instead of embedding it blindly (#4): flag rows that
    # lack an accession rather than printing a silently-broken table.
    while IFS=$'\t' read -r sp acc _rest; do
      [[ -z "${sp}" ]] && continue
      if [[ -z "${acc}" ]]; then
        echo "| ${sp} | **MISSING/INVALID accession** |"
      else
        echo "| ${sp} | ${acc} |"
      fi
    done < "${PROJECT_ROOT}/accessions.tsv"
  else
    echo "| *accessions.tsv missing or empty* | - |"
  fi
  echo ""

  # ── Tree ────────────────────────────────────────────────────────────────
  echo "## Phylogenetic Tree"
  echo ""
  echo '```'
  echo "${NEWICK_TREE}"
  echo '```'
  echo ""

  # ── Genome stats ────────────────────────────────────────────────────────
  echo "## Input Genome Statistics"
  echo ""
  if [[ -f "${QC_DIR}/genome_checksums.tsv" ]]; then
    echo "| Species | SHA256 (first 12) | Size (bytes) | Sequences | Total bp |"
    echo "|---------|-------------------|-------------|-----------|----------|"
    while IFS=$'\t' read -r sp sha sz nseq bp; do
      echo "| ${sp} | ${sha:0:12}... | ${sz} | ${nseq} | ${bp} |"
    done < "${QC_DIR}/genome_checksums.tsv"
  else
    echo "*Genome checksums not available (step 01 not run)*"
  fi
  echo ""

  # ── Test HAL results ────────────────────────────────────────────────────
  echo "## Test Alignment (1 Mb)"
  echo ""
  if [[ -f "${QC_DIR}/test_halValidate.txt" ]]; then
    echo "- **halValidate**: $(cat "${QC_DIR}/test_halValidate.txt")"
  else
    echo "- **halValidate**: not run"
  fi
  if [[ -f "${QC_DIR}/test_halStats.txt" ]]; then
    echo ""
    echo '```'
    cat "${QC_DIR}/test_halStats.txt"
    echo '```'
  fi
  echo ""

  # ── Full HAL results ────────────────────────────────────────────────────
  echo "## Full Alignment"
  echo ""
  if [[ -f "${QC_DIR}/full_halValidate.txt" ]]; then
    echo "- **halValidate**: $(cat "${QC_DIR}/full_halValidate.txt")"
  else
    echo "- **halValidate**: not run yet"
  fi
  if [[ -f "${QC_DIR}/full_halStats.txt" ]]; then
    echo ""
    echo '```'
    cat "${QC_DIR}/full_halStats.txt"
    echo '```'
  fi
  echo ""

  # ── Extracted ancestors ─────────────────────────────────────────────────
  echo "## Extracted Ancestors"
  echo ""
  # N-fraction column (#4): surface degenerate (mostly-N) ancestors so the
  # report cannot present a garbage reconstruction as a clean success.
  echo "| Ancestor | File | Size | N-fraction | Quality |"
  echo "|----------|------|------|-----------|---------|"
  WARN_NF="${HOMOPAN_WARN_N_FRAC:-0.50}"; DEGEN=0
  for anc in "${ANCESTOR_NODES[@]}"; do
    FA="${RESULTS_ANCESTORS}/${anc}.fa"
    if [[ -f "${FA}" ]]; then
      SZ=$(du -h "${FA}" | cut -f1)
      NF=$(awk -F'\t' -v a="${anc}" '$1==a{print $4}' "${QC_DIR}/ancestor_checksums.tsv" 2>/dev/null)
      [[ -z "${NF}" ]] && NF="NA"
      Q="OK"
      if [[ "${NF}" != "NA" ]] && awk "BEGIN{exit !(${NF} > ${WARN_NF})}"; then
        Q="LOW-CONFIDENCE (mostly N)"; DEGEN=1
      fi
      echo "| ${anc} | ${FA#${PROJECT_ROOT}/} | ${SZ} | ${NF} | ${Q} |"
    else
      echo "| ${anc} | *not extracted yet* | - | - | - |"
    fi
  done
  echo ""
  if (( DEGEN == 1 )); then
    echo "> **WARNING:** one or more ancestors exceed the N-fraction warning threshold (${WARN_NF})."
    echo "> Those reconstructions are LOW-CONFIDENCE and must NOT be interpreted biologically."
    echo ""
  fi

  # ── Output files ────────────────────────────────────────────────────────
  echo "## Output Files"
  echo ""
  echo '```'
  find "${RESULTS_DIR}" -type f -name "*.hal" -o -name "*.fa" -o -name "*.md" 2>/dev/null \
    | sort | while read -r f; do
      echo "$(du -h "$f" | cut -f1)  $(sanitize_path "$f")"
    done
  echo '```'
  echo ""

  # ── Environment ─────────────────────────────────────────────────────────
  echo "## Environment"
  echo ""
  if [[ -f "${QC_DIR}/environment.txt" ]]; then
    echo '```'
    cat "${QC_DIR}/environment.txt"
    echo '```'
  else
    echo "*Environment not captured*"
  fi
  echo ""

  # ── Provenance / reproducibility (#1, #5) ────────────────────────────────
  echo "## Provenance"
  echo ""
  echo "Per-run manifest (immutable, for rigorous run-to-run comparison):"
  echo '```'
  echo "${QC_DIR#${PROJECT_ROOT}/}/manifests/${RUN_ID}.json"
  echo '```'
  echo "Compare two runs: \`bash scripts/compare_runs.sh <run_id_a> <run_id_b>\`"
  echo ""

  # ── Caveats ─────────────────────────────────────────────────────────────
  echo "## Caveats"
  echo ""
  echo "1. The 1 Mb test uses a single contig fragment -- it is a **technical test only**."
  echo "2. Biological interpretation requires full genome alignment or confirmed orthologous regions."
  echo "3. Assembly quality (gaps, repeats, misassemblies) affects ancestral reconstruction."
  echo "4. Ancestral FASTA sequences are **inferred**, not observed genomes."
  echo "5. Target-region analysis requires coordinate and orthology validation."
  echo ""

  # ── Conclusion ──────────────────────────────────────────────────────────
  echo "## Conclusion"
  echo ""
  echo "The Homo-Pan ancestor reconstruction is technically valid if:"
  echo "- Cactus completed successfully"
  echo "- halValidate passed for the output HAL"
  echo "- halStats reports the expected tree and all 9 genomes (5 species + 4 ancestors)"
  echo "- Anc_HomoPan.fa was extracted successfully"
  echo ""

} > "${REPORT}"

log_ok "Report written to $(sanitize_path "${REPORT}")"

# Immutable per-run manifest: tool versions, SIF digest, seed, params, and
# input/output hashes -- enables rigorous comparison/replay across runs (#1,#5).
write_run_manifest

mark_done "09_make_report"
