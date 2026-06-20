#!/usr/bin/env bash
# cgv_12_align_mashmap.sh -- MashMap v3 (approximate, alignment-free mapping).
# ref = human, query = bonobo  =>  PAF target = human (X), query = bonobo (Y).
# Produces homology SEGMENTS with an estimated identity (NO base-level CIGAR);
# this is the fast synteny-map aligner and its identity is approximate by design.
source "$(dirname "${BASH_SOURCE[0]}")/cgv_config.sh"

cgv_banner "CGV step 12 -- MashMap (mode=${CGV_MODE})"
cgv_require_tool mashmap
[[ -s "${HUMAN_ACTIVE}" ]]  || die "Human FASTA missing: ${HUMAN_ACTIVE} (run cgv_03)"
[[ -s "${BONOBO_ACTIVE}" ]] || die "Bonobo FASTA missing: ${BONOBO_ACTIVE} (run cgv_03)"

if cgv_is_done cgv_12_align_mashmap && [[ -s "${CGV_BLOCKS_DIR}/mashmap.blocks.tsv" ]]; then
  log_ok "MashMap already done; skipping."; exit 0
fi

THREADS="${CGV_THREADS:-$(nproc 2>/dev/null || echo 4)}"
RAW="${CGV_BLOCKS_DIR}/mashmap.paf"
OUT="${CGV_BLOCKS_DIR}/mashmap.blocks.tsv"
mkdir -p "${CGV_BLOCKS_DIR}"
SEG="${CGV_MASHMAP_SEG:-5000}"
PI="${CGV_MASHMAP_PI:-90}"

if [[ -s "${RAW}" && "${CGV_FORCE_ALIGN:-0}" != "1" && "${RAW}" -nt "${HUMAN_ACTIVE}" && "${RAW}" -nt "${BONOBO_ACTIVE}" ]]; then
  log_info "Reusing existing mashmap.paf (newer than inputs); re-normalizing only. CGV_FORCE_ALIGN=1 to redo."
else
  log_step "mashmap -r human -q bonobo -s ${SEG} --pi ${PI} -t ${THREADS}"
  cgv_run mashmap -r "${HUMAN_ACTIVE}" -q "${BONOBO_ACTIVE}" \
    -s "${SEG}" --pi "${PI}" -t "${THREADS}" -o "${RAW}.tmp" 2> "${CGV_BLOCKS_DIR}/mashmap.log" \
    || { tail -10 "${CGV_BLOCKS_DIR}/mashmap.log" >&2; die "mashmap failed"; }
  mv -f "${RAW}.tmp" "${RAW}"
fi
log_info "MashMap produced $(grep -vc '^#' "${RAW}" 2>/dev/null || wc -l < "${RAW}") records"

# Normalize PAF. query(1,3,4)=bonobo ; target(6,8,9)=human ; strand col5 ;
# identity from the id:f: tag (a percentage), fallback dv:f / col10:col11.
{
  printf '#aligner\thuman_chr\th_start\th_end\tbonobo_chr\tb_start\tb_end\tstrand\tidentity_pct\n'
  awk -F'\t' -v ho="${CGV_H_OFFSET:-0}" -v bo="${CGV_B_OFFSET:-0}" '
    /^#/ { next }
    NF>=11 {
      qn=$1; qs=$3; qe=$4; st=$5; tn=$6; ts=$8; te=$9; nm=$10; bl=$11;
      id="";
      for(i=12;i<=NF;i++){
        # MashMap reports id:f: as a FRACTION (0..1) -> scale to percent.
        if($i ~ /^id:f:/) id=substr($i,6)*100;
        else if($i ~ /^dv:f:/ && id=="") id=(1-substr($i,6))*100;
      }
      if(id=="") id=(bl>0 ? nm/bl*100 : 0);
      printf "mashmap\t%s\t%d\t%d\t%s\t%d\t%d\t%s\t%.4f\n", tn, ts+ho, te+ho, qn, qs+bo, qe+bo, st, id;
    }
  ' "${RAW}"
} > "${OUT}.tmp"
mv -f "${OUT}.tmp" "${OUT}"

n=$(grep -vc '^#' "${OUT}")
(( n > 0 )) || log_warn "MashMap produced 0 normalized blocks (check mashmap.log)."
log_ok "MashMap normalized ${n} blocks -> $(basename "${OUT}")"
cgv_mark_done cgv_12_align_mashmap
