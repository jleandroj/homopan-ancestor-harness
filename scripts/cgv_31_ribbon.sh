#!/usr/bin/env bash
# cgv_31_ribbon.sh -- canonical NCBI-CGV-style ribbon figure (the "v09" look:
# big synteny only, clean green/blue, chromosome bars y1=bonobo / y2=human).
#
# Genome-wide and mode-independent: always renders the NCBI ground-truth ribbon
# (the structural overview that matches the official CGV SVG). In full mode it
# also renders the ribbon from our own minimap2 alignment (genome-wide), so the
# report can show "ours vs NCBI" in the same idiom.
source "$(dirname "${BASH_SOURCE[0]}")/cgv_config.sh"

cgv_banner "CGV step 31 -- ribbon figure (NCBI-style, v09)"
cgv_require_tool python3
[[ -s "${TRUTH_BLOCKS}" ]] || die "truth_blocks missing; run cgv_01 first."

HF="${CGV_GENOMES_DIR}/human.fa.fai"; [[ -s "$HF" ]] || HF="${HUMAN_FA}.fai"
BF="${PROJECT_ROOT}/genomes/pan_paniscus.fa.fai"; [[ -s "$BF" ]] || BF="${BONOBO_FA}.fai"
HN="${CGV_TRUTH_DIR}/human_chr_names.tsv"; BN="${CGV_TRUTH_DIR}/bonobo_chr_names.tsv"

# Fetch chromosome name maps if absent (needed for ordering + labels).
for pair in "${HUMAN_ACC}:${HN}" "${BONOBO_ACC}:${BN}"; do
  acc="${pair%%:*}"; out="${pair##*:}"
  if [[ ! -s "$out" ]]; then
    cgv_require_tool datasets
    log_step "Fetching chromosome names for ${acc}"
    datasets summary genome accession "$acc" --report sequence --as-json-lines 2>/dev/null \
      | jq -rc 'select(.role=="assembled-molecule") | [.refseq_accession, .chr_name] | @tsv' > "$out" || true
  fi
done
for f in "$HF" "$BF" "$HN" "$BN"; do
  [[ -s "$f" ]] || { log_warn "Ribbon skipped: missing ${f} (need both .fai + name maps)."; exit 0; }
done

mkdir -p "${CGV_FIGS_DIR}"

# Canonical v09 parameters (the look you approved): big synteny only, clean bands.
V09=(--min-bp "${CGV_RIBBON_MIN_BP:-200000}" --alpha "${CGV_RIBBON_ALPHA:-0.8}" --curve 0.5 --figw 24)

TRUTH_FIG="${CGV_FIGS_DIR}/cgv_ribbon_truth.png"
log_step "Rendering NCBI ground-truth ribbon -> $(basename "${TRUTH_FIG}")"
python3 "${CGV_SCRIPTS_DIR}/cgv_ribbon.py" \
  --blocks "${TRUTH_BLOCKS}" --source ncbi \
  --human-fai "$HF" --bonobo-fai "$BF" --human-names "$HN" --bonobo-names "$BN" \
  --title "NCBI CGV (ground truth) — Homo sapiens (y2) × Pan paniscus (y1)" \
  --out "${TRUTH_FIG}" "${V09[@]}" || die "ribbon render (truth) failed"

# Full mode: also render our own minimap2 alignment in the same style.
ALL="${CGV_RESULTS}/all_blocks.tsv"
if [[ "${CGV_MODE}" == "full" && -s "${ALL}" ]] && grep -q '^minimap2' "${ALL}"; then
  MM_FIG="${CGV_FIGS_DIR}/cgv_ribbon_minimap2.png"
  log_step "Rendering our minimap2 ribbon -> $(basename "${MM_FIG}")"
  python3 "${CGV_SCRIPTS_DIR}/cgv_ribbon.py" \
    --blocks "${ALL}" --source minimap2 \
    --human-fai "$HF" --bonobo-fai "$BF" --human-names "$HN" --bonobo-names "$BN" \
    --title "Ours (minimap2) — Homo sapiens (y2) × Pan paniscus (y1)" \
    --out "${MM_FIG}" "${V09[@]}" || log_warn "ribbon render (minimap2) failed"
fi

log_ok "Ribbon figure(s) -> ${CGV_FIGS_DIR}/"
ls -1 "${CGV_FIGS_DIR}"/cgv_ribbon_*.png 2>/dev/null >&2 || true
