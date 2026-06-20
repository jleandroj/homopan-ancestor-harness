#!/usr/bin/env bash
# cgv_10_align_minimap2.sh -- minimap2 asm20 (cross-species assembly preset).
# Reference = human, query = bonobo  =>  PAF target = human (X), query = bonobo (Y).
# Emits raw PAF + normalized blocks.tsv (gap-compressed identity from the de:f tag).
source "$(dirname "${BASH_SOURCE[0]}")/cgv_config.sh"

cgv_banner "CGV step 10 -- minimap2 (mode=${CGV_MODE})"
cgv_require_tool minimap2
[[ -s "${HUMAN_ACTIVE}" ]]  || die "Human FASTA missing: ${HUMAN_ACTIVE} (run cgv_03)"
[[ -s "${BONOBO_ACTIVE}" ]] || die "Bonobo FASTA missing: ${BONOBO_ACTIVE} (run cgv_03)"

if cgv_is_done cgv_10_align_minimap2 && [[ -s "${CGV_BLOCKS_DIR}/minimap2.blocks.tsv" ]]; then
  log_ok "minimap2 already done; skipping."; exit 0
fi

THREADS="${CGV_THREADS:-$(nproc 2>/dev/null || echo 4)}"
PAF="${CGV_BLOCKS_DIR}/minimap2.paf"
OUT="${CGV_BLOCKS_DIR}/minimap2.blocks.tsv"
mkdir -p "${CGV_BLOCKS_DIR}"

if [[ -s "${PAF}" && "${CGV_FORCE_ALIGN:-0}" != "1" && "${PAF}" -nt "${HUMAN_ACTIVE}" && "${PAF}" -nt "${BONOBO_ACTIVE}" ]]; then
  log_info "Reusing existing minimap2.paf (newer than inputs); re-normalizing only. CGV_FORCE_ALIGN=1 to redo."
else
  log_step "minimap2 -cx asm20 (threads=${THREADS})  human=$(basename "${HUMAN_ACTIVE}") bonobo=$(basename "${BONOBO_ACTIVE}")"
  cgv_run minimap2 -cx asm20 --cs -t "${THREADS}" "${HUMAN_ACTIVE}" "${BONOBO_ACTIVE}" > "${PAF}.tmp" \
    || die "minimap2 failed"
  mv -f "${PAF}.tmp" "${PAF}"
fi
log_info "minimap2 produced $(wc -l < "${PAF}") PAF records"

# Normalize: PAF target(6,8,9)=human ; query(1,3,4)=bonobo ; strand col5 ;
# identity = (1 - de)*100 from the de:f gap-compressed-divergence tag.
{
  printf '#aligner\thuman_chr\th_start\th_end\tbonobo_chr\tb_start\tb_end\tstrand\tidentity_pct\n'
  cgv_norm_paf minimap2 "${PAF}" "${CGV_H_OFFSET:-0}" "${CGV_B_OFFSET:-0}"
} > "${OUT}.tmp"
mv -f "${OUT}.tmp" "${OUT}"

n=$(grep -vc '^#' "${OUT}")
log_ok "minimap2 normalized ${n} blocks -> $(basename "${OUT}")"
cgv_mark_done cgv_10_align_minimap2
