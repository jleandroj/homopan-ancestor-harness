#!/usr/bin/env bash
# cgv_11_align_lastz.sh -- LASTZ (the UCSC/NCBI chain-alignment lineage).
# target = human (name1), query = bonobo (name2)  =>  human X, bonobo Y.
# Emits raw general-format output + normalized blocks.tsv.
#
# LASTZ is single-threaded and O(target*query); on whole chromosomes it is the
# slow aligner. We use a sensitivity/speed preset suited to ~98%-identity
# primate DNA and cap wall-time with CGV_LASTZ_TIMEOUT (default 2 h). For full
# mode the orchestrator runs it per human chromosome.
source "$(dirname "${BASH_SOURCE[0]}")/cgv_config.sh"

cgv_banner "CGV step 11 -- LASTZ (mode=${CGV_MODE})"
cgv_require_tool lastz
[[ -s "${HUMAN_ACTIVE}" ]]  || die "Human FASTA missing: ${HUMAN_ACTIVE} (run cgv_03)"
[[ -s "${BONOBO_ACTIVE}" ]] || die "Bonobo FASTA missing: ${BONOBO_ACTIVE} (run cgv_03)"

if cgv_is_done cgv_11_align_lastz && [[ -s "${CGV_BLOCKS_DIR}/lastz.blocks.tsv" ]]; then
  log_ok "LASTZ already done; skipping."; exit 0
fi

RAW="${CGV_BLOCKS_DIR}/lastz.general.tsv"
OUT="${CGV_BLOCKS_DIR}/lastz.blocks.tsv"
mkdir -p "${CGV_BLOCKS_DIR}"
TIMEOUT="${CGV_LASTZ_TIMEOUT:-7200}"

# General format with the exact fields we normalize. zstart2+/end2+ give the
# query interval on the query's FORWARD strand regardless of orientation, so
# the Y-axis coordinates stay consistent with PAF/GFF; strand2 carries +/-.
FORMAT='general:name1,zstart1,end1,name2,strand2,zstart2+,end2+,id%'

# Speed/sensitivity preset for high-identity large sequences:
#   [multiple]      treat the human FASTA as one or more sequences (target)
#   --step=20       sample every 20th seed position (faster, fine at ~98% id)
#   --notransition  no transition seeds (speed)
#   --gapped --chain  produce chained gapped blocks comparable to CGV blocks
#   --ambiguous=iupac tolerate IUPAC/N bases
LASTZ_OPTS=(--step="${CGV_LASTZ_STEP:-20}" --notransition --gapped --chain --ambiguous=iupac)

if [[ -s "${RAW}" && "${CGV_FORCE_ALIGN:-0}" != "1" && "${RAW}" -nt "${HUMAN_ACTIVE}" && "${RAW}" -nt "${BONOBO_ACTIVE}" ]]; then
  log_info "Reusing existing lastz.general.tsv (newer than inputs); re-normalizing only. CGV_FORCE_ALIGN=1 to redo."
else
  log_step "lastz ${HUMAN_ACTIVE##*/}[multiple] ${BONOBO_ACTIVE##*/} (timeout ${TIMEOUT}s, opts: ${LASTZ_OPTS[*]})"
  set +e
  cgv_run timeout "${TIMEOUT}" lastz "${HUMAN_ACTIVE}[multiple]" "${BONOBO_ACTIVE}" \
    "${LASTZ_OPTS[@]}" --format="${FORMAT}" > "${RAW}.tmp" 2> "${CGV_BLOCKS_DIR}/lastz.log"
  rc=$?
  set -e
  if (( rc == 124 )); then
    die "LASTZ timed out after ${TIMEOUT}s. Increase CGV_LASTZ_TIMEOUT or raise --step (CGV_LASTZ_STEP)."
  elif (( rc != 0 )); then
    log_error "LASTZ failed (exit ${rc}); tail of log:"; tail -10 "${CGV_BLOCKS_DIR}/lastz.log" >&2
    die "LASTZ failed."
  fi
  mv -f "${RAW}.tmp" "${RAW}"
fi
log_info "LASTZ produced $(grep -vc '^#' "${RAW}") raw records"

# Normalize. Raw cols: name1 zstart1 end1 name2 strand2 zstart2+ end2+ idPct
# name1/zstart1/end1 = human (0-based half-open) ; name2/zstart2+/end2+ = bonobo.
{
  printf '#aligner\thuman_chr\th_start\th_end\tbonobo_chr\tb_start\tb_end\tstrand\tidentity_pct\n'
  cgv_norm_lastz "${RAW}" "${CGV_H_OFFSET:-0}" "${CGV_B_OFFSET:-0}"
} > "${OUT}.tmp"
mv -f "${OUT}.tmp" "${OUT}"

n=$(grep -vc '^#' "${OUT}")
(( n > 0 )) || log_warn "LASTZ produced 0 normalized blocks (check lastz.log / preset)."
log_ok "LASTZ normalized ${n} blocks -> $(basename "${OUT}")"
cgv_mark_done cgv_11_align_lastz
