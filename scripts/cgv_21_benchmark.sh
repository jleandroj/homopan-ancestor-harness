#!/usr/bin/env bash
# cgv_21_benchmark.sh -- Score each aligner against the NCBI ground truth.
#
# On the HUMAN axis (the shared coordinate system), using merged intervals:
#   recall    = bp(truth ∩ aligner) / bp(truth)        how much of CGV we recover
#   precision = bp(truth ∩ aligner) / bp(aligner)      how much of ours is in CGV
#   jaccard   = bp(intersection) / bp(union)
# Plus strand concordance (forward fraction vs truth) and median identity.
# In test mode, truth is restricted to the selected chromosome pair (the only
# sequences the aligners were given).
source "$(dirname "${BASH_SOURCE[0]}")/cgv_config.sh"

cgv_banner "CGV step 21 -- benchmark vs ground truth"
cgv_require_tool bedtools
[[ -s "${TRUTH_BLOCKS}" ]] || die "Ground-truth blocks missing; run cgv_01."

TMP="$(mktemp -d "${CGV_RESULTS}/.bench.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# Truth restricted to the test pair (test) or all (full), as a human-axis BED.
region_h=""; region_b=""; HS=0; HE=0; BS=0; BE=0
if [[ "${CGV_MODE}" == "test" && -s "${REGION_FILE}" ]]; then
  region_h=$(cgv_region_get human accNA); region_b=$(cgv_region_get bonobo accNA)
  HS="${CGV_H_OFFSET}"; HE="${CGV_H_END}"; BS="${CGV_B_OFFSET}"; BE="${CGV_B_END}"
fi

# Box predicate (awk): keep a block only if it falls in the test box. In full
# mode HE/BE are 0 -> the predicate is a no-op (keep all).
#   $2,$3 = human chr,start ; $5,$6 = bonobo chr,start
# Emit a human-axis BED (chr,start,end) for a blocks file, box-restricted,
# sorted + merged.
blocks_to_human_bed() {   # <blocks_file> <out_bed>
  awk -F'\t' -v h="${region_h}" -v b="${region_b}" -v hs="${HS}" -v he="${HE}" -v bs="${BS}" -v be="${BE}" '
    $1!~/^#/ {
      if(h!="" && !($2==h && $5==b)) next;
      if(he+0>0 && !($3>=hs && $3<he && $6>=bs && $6<be)) next;
      print $2"\t"$3"\t"$4;
    }' "$1" | sort -k1,1 -k2,2n | bedtools merge -i - > "$2"
}
bed_bp() { awk '{s+=$3-$2} END{print s+0}' "$1"; }

# Truth BED
blocks_to_human_bed "${TRUTH_BLOCKS}" "${TMP}/truth.bed"
truth_bp=$(bed_bp "${TMP}/truth.bed")
(( truth_bp > 0 )) || die "Truth has 0 bp on the human axis for the selected scope."

# Truth strand fraction & identity (same scope)
read -r truth_f truth_r truth_med < <(awk -F'\t' -v h="${region_h}" -v b="${region_b}" -v hs="${HS}" -v he="${HE}" -v bs="${BS}" -v be="${BE}" '
  $1!~/^#/ {
    if(h!="" && !($2==h && $5==b)) next;
    if(he+0>0 && !($3>=hs && $3<he && $6>=bs && $6<be)) next;
    n++; if($8=="+")f++; else r++; v[n]=$9+0;
  }
  END{
    med="NA";
    if(n>0){ for(i=2;i<=n;i++){k=v[i];j=i-1;while(j>0&&v[j]>k){v[j+1]=v[j];j--}v[j+1]=k} m=int((n+1)/2); med=(n%2?v[m]:(v[m]+v[m+1])/2) }
    printf "%d %d %s\n", f+0, r+0, (n>0?sprintf("%.2f",med):"NA");
  }' "${TRUTH_BLOCKS}")
truth_fwd_frac=$(awk -v f="${truth_f}" -v r="${truth_r}" 'BEGIN{t=f+r; printf "%.4f", (t>0?f/t:0)}')

OUT="${CGV_BENCHMARK}"
{
  printf 'aligner\tblocks\trecall\tprecision\tjaccard\taligner_bp\ttruth_bp\tfwd_frac\tfwd_frac_truth\tmedian_id\tmedian_id_truth\n'
  for a in "${CGV_ALIGNERS[@]}"; do
    bf="${CGV_BLOCKS_DIR}/${a}.blocks.tsv"
    if [[ ! -s "${bf}" ]]; then
      printf '%s\t0\tNA\tNA\tNA\t0\t%d\tNA\t%s\tNA\t%s\n' "$a" "${truth_bp}" "${truth_fwd_frac}" "${truth_med}"
      continue
    fi
    blocks_to_human_bed "${bf}" "${TMP}/${a}.bed"
    aln_bp=$(bed_bp "${TMP}/${a}.bed")
    inter_bp=$(bedtools intersect -a "${TMP}/truth.bed" -b "${TMP}/${a}.bed" 2>/dev/null | awk '{s+=$3-$2} END{print s+0}')
    union_bp=$(( truth_bp + aln_bp - inter_bp ))
    nblk=$(grep -vc '^#' "${bf}")
    recall=$(awk -v i="${inter_bp}" -v t="${truth_bp}" 'BEGIN{printf "%.4f",(t>0?i/t:0)}')
    prec=$(awk -v i="${inter_bp}" -v a="${aln_bp}" 'BEGIN{printf "%.4f",(a>0?i/a:0)}')
    jac=$(awk -v i="${inter_bp}" -v u="${union_bp}" 'BEGIN{printf "%.4f",(u>0?i/u:0)}')
    # aligner strand fraction + median identity (region-scoped to match truth)
    read -r af ar amed < <(awk -F'\t' -v h="${region_h}" -v b="${region_b}" -v hs="${HS}" -v he="${HE}" -v bs="${BS}" -v be="${BE}" '
      $1!~/^#/ {
        if(h!="" && !($2==h && $5==b)) next;
        if(he+0>0 && !($3>=hs && $3<he && $6>=bs && $6<be)) next;
        n++; if($8=="+")f++; else r++; v[n]=$9+0;
      }
      END{
        med="NA";
        if(n>0){ for(i=2;i<=n;i++){k=v[i];j=i-1;while(j>0&&v[j]>k){v[j+1]=v[j];j--}v[j+1]=k} m=int((n+1)/2); med=(n%2?v[m]:(v[m]+v[m+1])/2) }
        printf "%d %d %s\n", f+0, r+0, (n>0?sprintf("%.2f",med):"NA");
      }' "${bf}")
    afrac=$(awk -v f="${af}" -v r="${ar}" 'BEGIN{t=f+r; printf "%.4f",(t>0?f/t:0)}')
    printf '%s\t%d\t%s\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%s\n' \
      "$a" "${nblk}" "${recall}" "${prec}" "${jac}" "${aln_bp}" "${truth_bp}" "${afrac}" "${truth_fwd_frac}" "${amed}" "${truth_med}"
  done
} > "${OUT}.tmp"
mv -f "${OUT}.tmp" "${OUT}"

log_ok "Benchmark -> $(basename "${OUT}")"
column -t -s$'\t' "${OUT}" | sed 's/^/    /' >&2
