#!/usr/bin/env bash
# cgv_40_report.sh -- Assemble the markdown report + a provenance manifest for
# the CGV replication run (benchmark table, figure, strand counts, caveats).
source "$(dirname "${BASH_SOURCE[0]}")/cgv_config.sh"

cgv_banner "CGV step 40 -- report"
[[ -s "${CGV_BENCHMARK}" ]] || die "Benchmark missing; run cgv_21 first."
mkdir -p "${CGV_RESULTS}"

fig="${CGV_FIGS_DIR}/cgv_synteny_${CGV_MODE}.png"
region_line="whole genome"
if [[ "${CGV_MODE}" == "test" && -s "${REGION_FILE}" ]]; then
  hc=$(awk -F'\t' '$1=="human"{print $2}' "${REGION_FILE}")
  bc=$(awk -F'\t' '$1=="bonobo"{print $2}' "${REGION_FILE}")
  region_line="test chromosome pair: human \`${hc}\` x bonobo \`${bc}\`"
fi

md_table() {  # tsv -> github markdown table
  awk -F'\t' 'NR==1{n=NF; printf "|"; for(i=1;i<=NF;i++)printf" %s |",$i; printf"\n|"; for(i=1;i<=NF;i++)printf" --- |"; printf"\n"; next}
              {printf "|"; for(i=1;i<=NF;i++)printf" %s |",$i; printf"\n"}' "$1"
}

# Pull truth strand counts for the headline.
tf=$(awk -F'\t' '$1=="total_blocks"{next} $1=="forward"{print $2}' "${CGV_TRUTH_DIR}/truth_stats.tsv" 2>/dev/null)
tr=$(awk -F'\t' '$1=="reverse"{print $2}' "${CGV_TRUTH_DIR}/truth_stats.tsv" 2>/dev/null)
tt=$(awk -F'\t' '$1=="total_blocks"{print $2}' "${CGV_TRUTH_DIR}/truth_stats.tsv" 2>/dev/null)

{
cat <<EOF
# CGV Replication Report -- Homo sapiens x Pan paniscus

**Mode:** \`${CGV_MODE}\`  |  **Scope:** ${region_line}
**Generated:** $(date -Iseconds)

## Objective

Independently re-derive NCBI's Comparative Genome Viewer (CGV) assembly-vs-assembly
alignment between human **${HUMAN_ACC}** (T2T-CHM13v2.0) and bonobo
**${BONOBO_ACC}** (mPanPan1.1) from raw DNA, with three aligners, and benchmark
each against NCBI's official ASMASM GFF used as ground truth.

## Ground truth (official NCBI ASMASM v3.2)

Whole-genome official alignment: **${tt} blocks** -- **${tf} forward (+)** /
**${tr} reverse (-)**. The reverse blocks are the inversions CGV renders on the
opposite diagonal.

## Benchmark (this run)

Scored on the shared **human axis** with merged intervals. \`recall\` = fraction
of CGV-aligned human bases we recover; \`precision\` = fraction of our aligned
bases that fall inside CGV blocks; \`fwd_frac\` vs \`fwd_frac_truth\` = strand
concordance; \`median_id\` vs \`median_id_truth\` = identity agreement.

$(md_table "${CGV_BENCHMARK}")

## Block counts per source

$(md_table "${CGV_RESULTS}/block_summary.tsv")

## Synteny figure (forward = blue, reverse = red)

![CGV synteny]($(realpath --relative-to="${CGV_RESULTS}" "${fig}" 2>/dev/null || echo "${fig}"))

Each block is a diagonal segment (human X, bonobo Y); reverse blocks are drawn as
anti-diagonals so inversions appear as the mirror diagonal -- the same
forward/reverse view as the official CGV \`.svg\`.

## Method

| step | tool | command core |
| --- | --- | --- |
| download | ncbi-datasets-cli | \`datasets download genome accession ${HUMAN_ACC}\` |
| minimap2 | minimap2 | \`minimap2 -cx asm20 --cs human bonobo\` |
| LASTZ | lastz | \`lastz human[multiple] bonobo --gapped --chain\` |
| MashMap | mashmap | \`mashmap -r human -q bonobo -s 5000 --pi 90\` |
| benchmark | bedtools | merged-interval recall/precision/jaccard vs truth |

## Caveats (biological + technical)

- **The three aligners approximate NCBI's in-house ASMASM engine** (v3.2); they
  are not expected to be byte-identical to it. The benchmark measures *agreement*,
  not correctness of CGV itself.
- **MashMap is alignment-free**: its blocks are approximate homology segments with
  an *estimated* identity and no base-level CIGAR -- treat its identity column as
  a coarse estimate.
- **LASTZ** uses a speed preset (\`--step\`, \`--notransition\`); raising
  sensitivity changes block counts.
EOF
if [[ "${CGV_MODE}" == "test" ]]; then
cat <<EOF
- **Test scope is technical-only**: a single chromosome pair, chosen as the
  human chromosome with the most CGV blocks and its dominant bonobo homolog. It
  validates the pipeline; it is not a genome-wide result. Run \`run_all_cgv_full.sh\`
  for the whole-genome comparison.
EOF
fi
} > "${CGV_REPORT}.tmp"
mv -f "${CGV_REPORT}.tmp" "${CGV_REPORT}"

# ── Provenance manifest (lightweight, schema mirrors the repo's repro idea) ─
if command -v jq >/dev/null 2>&1; then
  hsha=$(compute_sha256 "${HUMAN_ACTIVE}" 2>/dev/null || echo NA)
  bsha=$(compute_sha256 "${BONOBO_ACTIVE}" 2>/dev/null || echo NA)
  jq -n \
    --arg mode "${CGV_MODE}" --arg human "${HUMAN_ACC}" --arg bonobo "${BONOBO_ACC}" \
    --arg gff "$(basename "${TRUTH_GFF}")" \
    --arg mm "$(minimap2 --version 2>/dev/null)" \
    --arg lz "$(lastz --version 2>&1 | head -1)" \
    --arg ms "$(mashmap --version 2>&1 | head -1)" \
    --arg hsha "${hsha}" --arg bsha "${bsha}" \
    '{schema:1, mode:$mode, accessions:{human:$human, bonobo:$bonobo},
      ground_truth_gff:$gff,
      aligners:{minimap2:$mm, lastz:$lz, mashmap:$ms},
      inputs:{human_fa_sha256:$hsha, bonobo_fa_sha256:$bsha}}' \
    > "${CGV_MANIFEST}" 2>/dev/null || log_warn "manifest write skipped"
  [[ -s "${CGV_MANIFEST}" ]] && log_ok "Manifest -> $(basename "${CGV_MANIFEST}")"
fi

log_ok "Report -> ${CGV_REPORT}"
echo "" >&2
sed -n '1,40p' "${CGV_REPORT}" >&2
