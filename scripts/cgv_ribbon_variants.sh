#!/usr/bin/env bash
# cgv_ribbon_variants.sh -- generate NCBI-CGV-style ribbon plots (chromosome
# bars y1=bonobo / y2=human, green=forward / blue=reverse) from the normalized
# blocks, in several visual variants for comparison against the official CGV SVG.
#
# Needs: cgv_truth/truth_blocks.tsv (cgv_01), the two .fai, and the chr name maps
# (cgv_truth/{human,bonobo}_chr_names.tsv; fetched on demand from NCBI Datasets).
source "$(dirname "${BASH_SOURCE[0]}")/cgv_config.sh"

cgv_banner "CGV ribbon plots (NCBI-style)"
cgv_require_tool python3
[[ -s "${TRUTH_BLOCKS}" ]] || die "truth_blocks missing; run cgv_01 first."

HF="${CGV_GENOMES_DIR}/human.fa.fai"; [[ -s "$HF" ]] || HF="${HUMAN_FA}.fai"
BF="${PROJECT_ROOT}/genomes/pan_paniscus.fa.fai"; [[ -s "$BF" ]] || BF="${BONOBO_FA}.fai"
HN="${CGV_TRUTH_DIR}/human_chr_names.tsv"; BN="${CGV_TRUTH_DIR}/bonobo_chr_names.tsv"

# Fetch chromosome name maps if absent.
for pair in "${HUMAN_ACC}:${HN}" "${BONOBO_ACC}:${BN}"; do
  acc="${pair%%:*}"; out="${pair##*:}"
  if [[ ! -s "$out" ]]; then
    cgv_require_tool datasets
    log_step "Fetching chromosome names for ${acc}"
    datasets summary genome accession "$acc" --report sequence --as-json-lines 2>/dev/null \
      | jq -rc 'select(.role=="assembled-molecule") | [.refseq_accession, .chr_name] | @tsv' > "$out"
  fi
done
for f in "$HF" "$BF" "$HN" "$BN"; do [[ -s "$f" ]] || die "missing input: $f"; done

OUT="${CGV_RESULTS}/ribbon_attempts"; mkdir -p "${OUT}"
common=(--blocks "${TRUTH_BLOCKS}" --source ncbi --human-fai "$HF" --bonobo-fai "$BF" --human-names "$HN" --bonobo-names "$BN")
R(){ python3 "${CGV_SCRIPTS_DIR}/cgv_ribbon.py" "${common[@]}" "$@"; }

R --out "${OUT}/v01_baseline.png"         --title "v01 baseline (all blocks, bezier)" --alpha 0.5 --curve 0.5
R --out "${OUT}/v02_merge200k.png"        --title "v02 merge 200kb"        --merge-gap 200000 --alpha 0.6 --curve 0.5
R --out "${OUT}/v03_merge500k.png"        --title "v03 merge 500kb"        --merge-gap 500000 --alpha 0.7 --curve 0.45
R --out "${OUT}/v04_min100k.png"          --title "v04 min 100kb"          --min-bp 100000 --alpha 0.4 --curve 0.5
R --out "${OUT}/v05_flat_merge200k.png"   --title "v05 flatter, merge 200kb" --merge-gap 200000 --alpha 0.6 --curve 0.3
R --out "${OUT}/v06_min50k.png"           --title "v06 min 50kb"           --min-bp 50000 --alpha 0.55 --curve 0.5
R --out "${OUT}/v07_merge1M_straight.png" --title "v07 merge 1Mb, near-straight" --merge-gap 1000000 --alpha 0.75 --curve 0.15
R --out "${OUT}/v08_merge300k_edge.png"   --title "v08 merge 300kb + edges" --merge-gap 300000 --alpha 0.85 --curve 0.45 --edge 0.2
R --out "${OUT}/v09_bigonly_min200k.png"  --title "v09 big synteny only (min 200kb)" --min-bp 200000 --alpha 0.8 --curve 0.5
R --out "${OUT}/v10_wide_merge100k.png"   --title "v10 wide canvas, merge 100kb" --merge-gap 100000 --alpha 0.6 --curve 0.5 --gap-frac 0.008 --bar-h 0.05 --figw 26

# polished pick (closest to NCBI): clean big synteny, NCBI-like colors
R --out "${OUT}/final_NCBIstyle.png" --title "FINAL NCBI-style (from NCBI data)" \
  --min-bp 150000 --alpha 0.7 --curve 0.5 --green '#54b54c' --blue '#1f3fd0' --figw 24

log_ok "Ribbon variants -> ${OUT}/"
ls -1 "${OUT}/"
