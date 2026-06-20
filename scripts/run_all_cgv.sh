#!/usr/bin/env bash
# run_all_cgv.sh -- Orchestrate the CGV replication sub-pipeline end to end.
# Mode comes from CGV_MODE (test|full); the thin wrappers run_all_cgv_test.sh /
# run_all_cgv_full.sh set it. The three aligners run resiliently: if one fails or
# times out, the others still produce a (partial) benchmark and the failure is
# reported loudly -- the pipeline's purpose is COMPARISON, so partial is useful.
source "$(dirname "${BASH_SOURCE[0]}")/cgv_config.sh"

cgv_banner "RUN ALL -- CGV replication (mode=${CGV_MODE})"

# Single-run lock so two orchestrators don't clobber the same mode's outputs.
LOCK="${TARGETS_DIR}/cgv_${CGV_MODE}.lock"
exec {LFD}>"${LOCK}"
if ! flock -n "${LFD}"; then die "Another CGV ${CGV_MODE} run holds ${LOCK}."; fi

S="${CGV_SCRIPTS_DIR}"
run() { log_step "=> $1"; bash "${S}/$1"; }

# ── Setup + truth + genomes ────────────────────────────────────────────────
run cgv_00_check_env.sh
run cgv_01_normalize_truth.sh
run cgv_02_select_region.sh
run cgv_03_fetch_genomes.sh

# ── Aligners (resilient) ───────────────────────────────────────────────────
declare -A OK
ALIGN_STEPS=(minimap2:cgv_10_align_minimap2.sh mashmap:cgv_12_align_mashmap.sh)
# LASTZ whole-genome is impractical; in full mode it is opt-in (CGV_FULL_LASTZ=1).
if [[ "${CGV_MODE}" == "test" || "${CGV_FULL_LASTZ:-0}" == "1" ]]; then
  ALIGN_STEPS+=(lastz:cgv_11_align_lastz.sh)
else
  log_warn "Skipping LASTZ in full mode (set CGV_FULL_LASTZ=1 to include it; expect a long run)."
fi

for spec in "${ALIGN_STEPS[@]}"; do
  name="${spec%%:*}"; scr="${spec##*:}"
  log_step "=> ${scr} (aligner ${name})"
  if bash "${S}/${scr}"; then OK[$name]=1; else OK[$name]=0; log_warn "Aligner '${name}' FAILED; continuing with the rest."; fi
done

n_ok=0; for a in "${!OK[@]}"; do [[ "${OK[$a]}" == "1" ]] && n_ok=$((n_ok+1)); done
(( n_ok > 0 )) || die "All aligners failed; nothing to benchmark."

# ── Collect + benchmark + plot + report ───────────────────────────────────
run cgv_20_collect.sh
run cgv_21_benchmark.sh
run cgv_30_plot.sh
run cgv_40_report.sh

# ── Summary ────────────────────────────────────────────────────────────────
echo "" >&2
log_ok "CGV ${CGV_MODE} pipeline complete."
for spec in "${ALIGN_STEPS[@]}"; do
  name="${spec%%:*}"
  if [[ "${OK[$name]:-0}" == "1" ]]; then log_ok "  aligner ${name}: OK"; else log_warn "  aligner ${name}: FAILED"; fi
done
log_info "Report : ${CGV_REPORT}"
log_info "Figure : ${CGV_FIGS_DIR}/cgv_synteny_${CGV_MODE}.png"
log_info "Bench  : ${CGV_BENCHMARK}"
