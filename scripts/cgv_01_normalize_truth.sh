#!/usr/bin/env bash
# cgv_01_normalize_truth.sh -- Parse NCBI's official ASMASM GFF into a normalized,
# aligner-agnostic blocks table used as ground truth for the benchmark.
#
# Resolved orientation (verified against the local assemblies):
#   GFF seqid (col1) = HUMAN  CHM13v2.0 (NC_060925.1..NC_060948.1)  -> X axis
#   GFF Target       = BONOBO mPanPan1  (NC_073*/NC_085*)           -> Y axis
#   Alignment strand = the Target strand field (+ forward, - reverse).
#
# Output schema (TSV, 0-based half-open on BOTH axes; header line is '#'-prefixed):
#   aligner human_chr h_start h_end bonobo_chr b_start b_end strand identity_pct
# The truth rows carry aligner='ncbi'. identity_pct = pct_identity_gap.
source "$(dirname "${BASH_SOURCE[0]}")/cgv_config.sh"

cgv_banner "CGV step 01 -- normalize ground-truth GFF"

if cgv_is_done cgv_01_normalize_truth && [[ -s "${TRUTH_BLOCKS}" ]]; then
  log_ok "Already normalized: ${TRUTH_BLOCKS} ($(grep -vc '^#' "${TRUTH_BLOCKS}") blocks). Skipping."
  exit 0
fi

[[ -s "${TRUTH_GFF}" ]] || die "Official GFF missing: ${TRUTH_GFF}"
mkdir -p "${CGV_TRUTH_DIR}"

# Keep a copy of the official GFF alongside the normalized table (provenance).
if [[ ! -e "${CGV_TRUTH_DIR}/$(basename "${TRUTH_GFF}")" ]]; then
  cp -n "${TRUTH_GFF}" "${CGV_TRUTH_DIR}/" 2>/dev/null || true
fi

log_step "Parsing match records -> ${TRUTH_BLOCKS}"
{
  printf '#aligner\thuman_chr\th_start\th_end\tbonobo_chr\tb_start\tb_end\tstrand\tidentity_pct\n'
  awk -F'\t' '
    $3=="match" {
      # Reconstruct the attribute column even if a tab leaked into the CIGAR:
      # concatenate fields 9..NF back into one attribute string.
      attr=$9; for(i=10;i<=NF;i++) attr=attr "\t" $i;
      # Target=<bonobo_chr> <start> <end> <target_strand>
      if (match(attr, /Target=([^ ]+) ([0-9]+) ([0-9]+) ([+-])/, t)) {
        bchr=t[1]; bstart=t[2]; bend=t[3];
        # RELATIVE orientation = feature strand (col7, on human) combined with the
        # target strand (on bonobo): same sign => forward, opposite => reverse.
        # Using the target strand alone is wrong whenever col7 is "-".
        strand=($7==t[4])?"+":"-";
      } else { next }
      # identity: prefer pct_identity_gap, fall back to pct_identity_ungap
      pid="NA";
      if (match(attr, /pct_identity_gap=([0-9.]+)/, p)) pid=p[1];
      else if (match(attr, /pct_identity_ungap=([0-9.]+)/, p2)) pid=p2[1];
      hchr=$1; hstart=$4-1; hend=$5;   # GFF 1-based incl -> 0-based half-open
      b0=bstart-1;                      # same for bonobo axis
      printf "ncbi\t%s\t%d\t%d\t%s\t%d\t%d\t%s\t%s\n", hchr, hstart, hend, bchr, b0, bend, strand, pid;
    }
  ' "${TRUTH_GFF}"
} > "${TRUTH_BLOCKS}.tmp"
mv -f "${TRUTH_BLOCKS}.tmp" "${TRUTH_BLOCKS}"

# ── Sanity stats (must reconcile with the known split) ────────────────────
total=$(grep -vc '^#' "${TRUTH_BLOCKS}")
fwd=$(awk -F'\t' '$1=="ncbi" && $8=="+"' "${TRUTH_BLOCKS}" | wc -l)
rev=$(awk -F'\t' '$1=="ncbi" && $8=="-"' "${TRUTH_BLOCKS}" | wc -l)
nhc=$(awk -F'\t' '$1=="ncbi"{print $2}' "${TRUTH_BLOCKS}" | sort -u | wc -l)
nbc=$(awk -F'\t' '$1=="ncbi"{print $5}' "${TRUTH_BLOCKS}" | sort -u | wc -l)

log_info "Ground-truth blocks : ${total}"
log_info "  forward (+)       : ${fwd}"
log_info "  reverse (-)       : ${rev}"
log_info "  human chromosomes : ${nhc}"
log_info "  bonobo contigs    : ${nbc}"

# Write a small stats sidecar for the report.
cat > "${CGV_TRUTH_DIR}/truth_stats.tsv" <<EOF
metric	value
total_blocks	${total}
forward	${fwd}
reverse	${rev}
human_chromosomes	${nhc}
bonobo_contigs	${nbc}
EOF

(( total == fwd + rev )) || die "Strand counts do not reconcile (${fwd}+${rev} != ${total})."
(( total == 15734 )) || log_warn "Block count ${total} differs from the expected 15734 (GFF version drift?)."

log_ok "Normalized ${total} ground-truth blocks -> ${TRUTH_BLOCKS}"
cgv_mark_done cgv_01_normalize_truth
