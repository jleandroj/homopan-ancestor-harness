#!/usr/bin/env bash
# 09_make_report.sh -- Generate final Markdown report from actual outputs
set -euo pipefail
source "$(dirname "$0")/config.sh"

script_banner "09 - Generate Report"

REPORT="${RESULTS_REPORTS}/HomoPan_ancestor_report.md"

{
  echo "# HomoPan Ancestor Reconstruction Report"
  echo ""
  echo "Generated: $(date -Iseconds)"
  echo "Host: $(hostname)"
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
  while IFS=$'\t' read -r sp acc; do
    echo "| ${sp} | ${acc} |"
  done < "${PROJECT_ROOT}/accessions.tsv"
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
  echo "| Ancestor | File | Size |"
  echo "|----------|------|------|"
  for anc in "${ANCESTOR_NODES[@]}"; do
    FA="${RESULTS_ANCESTORS}/${anc}.fa"
    if [[ -f "${FA}" ]]; then
      SZ=$(du -h "${FA}" | cut -f1)
      echo "| ${anc} | results/ancestors/${anc}.fa | ${SZ} |"
    else
      echo "| ${anc} | *not extracted yet* | - |"
    fi
  done
  echo ""

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
mark_done "09_make_report"
