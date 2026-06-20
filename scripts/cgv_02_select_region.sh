#!/usr/bin/env bash
# cgv_02_select_region.sh -- Choose the test chromosome pair from the ground
# truth: the human chromosome carrying the most alignment blocks and its
# dominant bonobo homolog. Writes cgv_genomes/test/region.tsv consumed by the
# fetch step (test mode downloads only this pair). No network.
#
# Override the auto-pick with CGV_TEST_HUMAN_CHR / CGV_TEST_BONOBO_CHR.
source "$(dirname "${BASH_SOURCE[0]}")/cgv_config.sh"

cgv_banner "CGV step 02 -- select test chromosome pair"
[[ -s "${TRUTH_BLOCKS}" ]] || die "Ground-truth blocks missing; run cgv_01 first: ${TRUTH_BLOCKS}"
mkdir -p "${CGV_TEST_DIR}"

human="${CGV_TEST_HUMAN_CHR:-}"
bonobo="${CGV_TEST_BONOBO_CHR:-}"

if [[ -z "${human}" ]]; then
  human=$(awk -F'\t' '$1=="ncbi"{print $2}' "${TRUTH_BLOCKS}" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
fi
[[ -n "${human}" ]] || die "Could not determine a human chromosome from the truth table."

if [[ -z "${bonobo}" ]]; then
  bonobo=$(awk -F'\t' -v h="${human}" '$1=="ncbi" && $2==h{print $5}' "${TRUTH_BLOCKS}" \
            | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
fi
[[ -n "${bonobo}" ]] || die "Could not determine a bonobo homolog for ${human}."

pair=$(awk -F'\t' -v h="${human}" -v b="${bonobo}" '$1=="ncbi" && $2==h && $5==b' "${TRUTH_BLOCKS}" | wc -l)

# ── Pick the densest WxW homologous box on this pair ──────────────────────
# minimap2 chains a single whole-chromosome query single-threaded (slow), so the
# test aligns a small box on BOTH genomes. Bin truth blocks into WxW cells and
# take the cell with the most blocks; that box has real forward AND reverse
# blocks (it straddles the local diagonal/inversions).
W="${CGV_TEST_WINDOW_BP}"
read -r Hs He Bs Be boxn boxf boxr < <(awk -F'\t' -v h="${human}" -v b="${bonobo}" -v w="${W}" '
  $1=="ncbi" && $2==h && $5==b {
    hb=int($3/w); bb=int($6/w); key=hb"_"bb; c[key]++;
    if($8=="+")f[key]++; else r[key]++;
  }
  END{
    best=""; bc=-1;
    for(k in c) if(c[k]>bc){bc=c[k]; best=k}
    split(best,a,"_");
    Hs=a[1]*w; Bs=a[2]*w;
    printf "%d %d %d %d %d %d %d\n", Hs, Hs+w, Bs, Bs+w, bc, f[best]+0, r[best]+0;
  }' "${TRUTH_BLOCKS}")
[[ -n "${Hs}" ]] || die "Could not find a populated box for ${human} x ${bonobo}."

{
  printf '#role\taccession\n'
  printf 'human\t%s\n'  "${human}"
  printf 'bonobo\t%s\n' "${bonobo}"
  printf 'window_bp\t%s\n' "${W}"
  printf 'human_start\t%s\n'  "${Hs}"
  printf 'human_end\t%s\n'    "${He}"
  printf 'bonobo_start\t%s\n' "${Bs}"
  printf 'bonobo_end\t%s\n'   "${Be}"
} > "${REGION_FILE}.tmp"
mv -f "${REGION_FILE}.tmp" "${REGION_FILE}"

log_info "Test pair selected (from ground truth):"
log_info "  human  : ${human}  box [$((Hs/1000000))-$((He/1000000)) Mb]"
log_info "  bonobo : ${bonobo}  box [$((Bs/1000000))-$((Be/1000000)) Mb]"
log_info "  whole-chr-pair blocks: ${pair}"
log_info "  box blocks: ${boxn} (forward ${boxf} / reverse ${boxr})  -- the test scope"
log_ok "Wrote ${REGION_FILE}"
cgv_mark_done cgv_02_select_region
