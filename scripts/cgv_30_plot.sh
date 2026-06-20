#!/usr/bin/env bash
# cgv_30_plot.sh -- Render the CGV-style synteny figure (forward + reverse) for
# the ground truth and each aligner, via scripts/cgv_dotplot.py.
source "$(dirname "${BASH_SOURCE[0]}")/cgv_config.sh"

cgv_banner "CGV step 30 -- synteny plot"
cgv_require_tool python3
ALL="${CGV_RESULTS}/all_blocks.tsv"
[[ -s "${ALL}" ]] || die "Combined blocks missing; run cgv_20 first: ${ALL}"
mkdir -p "${CGV_FIGS_DIR}"

OUT="${CGV_FIGS_DIR}/cgv_synteny_${CGV_MODE}.png"
args=(--blocks "${ALL}" --out "${OUT}" --mode "${CGV_MODE}")
if [[ "${CGV_MODE}" == "test" && -s "${REGION_FILE}" ]]; then
  hc=$(awk -F'\t' '$1=="human"{print $2}' "${REGION_FILE}")
  bc=$(awk -F'\t' '$1=="bonobo"{print $2}' "${REGION_FILE}")
  args+=(--human-chr "${hc}" --bonobo-chr "${bc}")
fi

log_step "python3 cgv_dotplot.py ${args[*]}"
python3 "${CGV_SCRIPTS_DIR}/cgv_dotplot.py" "${args[@]}" || die "plotting failed"
log_ok "Figure -> ${OUT}"
ls -lh "${OUT}" >&2
