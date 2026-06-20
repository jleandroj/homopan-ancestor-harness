#!/usr/bin/env bash
# cgv_20_collect.sh -- Collect the normalized blocks from every aligner (+ the
# ground truth) into one table and emit a per-source summary. No comparison yet
# (that is cgv_21); this just assembles the inputs the plot/report consume.
source "$(dirname "${BASH_SOURCE[0]}")/cgv_config.sh"

cgv_banner "CGV step 20 -- collect blocks + summary"
[[ -s "${TRUTH_BLOCKS}" ]] || die "Ground-truth blocks missing; run cgv_01."

ALL="${CGV_RESULTS}/all_blocks.tsv"
SUMMARY="${CGV_RESULTS}/block_summary.tsv"
mkdir -p "${CGV_RESULTS}"

# In test mode the aligners only saw the selected chromosome pair, so the truth
# rows we collect (and later benchmark against) are restricted to that pair for
# a fair comparison. In full mode we keep all truth rows.
# In test mode restrict the truth to the homologous BOX (both axes); full mode
# keeps all truth rows.
truth_view() {
  if [[ "${CGV_MODE}" == "test" && -s "${REGION_FILE}" ]]; then
    local h b; h=$(cgv_region_get human accNA); b=$(cgv_region_get bonobo accNA)
    awk -F'\t' -v h="$h" -v b="$b" -v hs="${CGV_H_OFFSET}" -v he="${CGV_H_END}" \
                -v bs="${CGV_B_OFFSET}" -v be="${CGV_B_END}" \
      'NR==1 || ($1=="ncbi" && $2==h && $5==b && $3>=hs && $3<he && $6>=bs && $6<be)' "${TRUTH_BLOCKS}"
  else
    cat "${TRUTH_BLOCKS}"
  fi
}

# ── Combined table (single header; truth relabeled source 'ncbi') ─────────
{
  head -1 "${TRUTH_BLOCKS}"
  truth_view | grep -v '^#'
  for a in "${CGV_ALIGNERS[@]}"; do
    f="${CGV_BLOCKS_DIR}/${a}.blocks.tsv"
    [[ -s "$f" ]] && grep -v '^#' "$f" || true
  done
} > "${ALL}.tmp"
mv -f "${ALL}.tmp" "${ALL}"

# ── Per-source summary ─────────────────────────────────────────────────────
summarize() {   # <source_label> <blocks_file_or_->
  local label="$1" src="$2"
  awk -F'\t' -v L="$label" '
    $1!~/^#/ {
      n++; if($8=="+")f++; else if($8=="-")r++;
      hbp += ($4-$3);
      ids[n]=$9+0;
    }
    END{
      med="NA";
      if(n>0){
        # median identity
        for(i=1;i<=n;i++) a[i]=ids[i];
        # simple insertion sort (block counts are modest per source)
        for(i=2;i<=n;i++){ k=a[i]; j=i-1; while(j>0 && a[j]>k){a[j+1]=a[j];j--} a[j+1]=k }
        m=int((n+1)/2); med=(n%2? a[m] : (a[m]+a[m+1])/2);
      }
      printf "%s\t%d\t%d\t%d\t%d\t%s\n", L, n+0, f+0, r+0, hbp+0, (n>0?sprintf("%.2f",med):"NA");
    }'  "$src"
}

{
  printf 'source\tblocks\tforward\treverse\thuman_bp_sum\tmedian_identity_pct\n'
  truth_view | summarize "ncbi" -
  for a in "${CGV_ALIGNERS[@]}"; do
    f="${CGV_BLOCKS_DIR}/${a}.blocks.tsv"
    if [[ -s "$f" ]]; then summarize "$a" "$f"; else printf '%s\t0\t0\t0\t0\tNA\n' "$a"; fi
  done
} > "${SUMMARY}.tmp"
mv -f "${SUMMARY}.tmp" "${SUMMARY}"

log_ok "Collected blocks -> $(basename "${ALL}")"
log_info "Per-source summary:"
column -t -s$'\t' "${SUMMARY}" | sed 's/^/    /' >&2
