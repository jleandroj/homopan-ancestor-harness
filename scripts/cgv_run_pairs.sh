#!/usr/bin/env bash
# cgv_run_pairs.sh -- pairwise whole-genome synteny ribbons for a list of species
# pairs. For each pair (REF on the bottom bar y2, QUERY on the top bar y1):
#   minimap2 -cx asm20 --cs  ->  filter (primary + MAPQ>=30 + >=100kb)
#   -> normalize -> NCBI-style ribbon (natural chromosome order, green/blue).
#
# Genomes are reused from genomes/ or cgv_genomes/ when present, else downloaded
# from NCBI Datasets. Chromosome name maps are fetched on demand.
#
# SCOPE / VALIDITY: whole-genome DNA alignment (minimap2 asm20) is only
# meaningful for closely related species (great apes / hominoids, ~<25 My).
# It is NOT valid for distant taxa (other mammals are marginal; birds/fish/
# lamprey/amphioxus/echinoderms produce noise). Use ortholog/protein synteny for
# those. This driver intentionally ships only the hominoid pair list.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SD}/.." && pwd)"
source "${SD}/cgv_normalize.sh"
export PATH="${HOME}/miniconda3/envs/cgv_align/bin:${PATH}"

G="${ROOT}/genomes"; CG="${ROOT}/cgv_genomes"; NT="${ROOT}/cgv_truth"
OUT="${ROOT}/results/cgv/pairs"; DL="${CG}/.dl"
mkdir -p "${OUT}" "${CG}" "${NT}" "${DL}"
THREADS="${CGV_THREADS:-$(nproc 2>/dev/null || echo 8)}"
log(){ echo "[$(date +%H:%M:%S)] $*" >&2; }

# ── species registry: key -> label | accession | fasta | namesfile ─────────
declare -A LBL ACC FA NM
reg(){ LBL[$1]="$2"; ACC[$1]="$3"; FA[$1]="$4"; NM[$1]="$5"; }
reg human       "Homo sapiens"        GCF_009914755.1 "${CG}/human.fa"                    "${NT}/human_chr_names.tsv"
reg paniscus    "Pan paniscus"        GCF_029289425.2 "${G}/pan_paniscus.fa"              "${NT}/bonobo_chr_names.tsv"
reg troglodytes "Pan troglodytes"     GCF_028858775.2 "${G}/pan_troglodytes.fa"           "${NT}/troglodytes_chr_names.tsv"
reg gorilla     "Gorilla gorilla"     GCF_029281585.2 "${G}/gorilla_gorilla_gorilla.fa"   "${NT}/gorilla_chr_names.tsv"
reg pongo       "Pongo abelii"        GCF_028885655.2 "${G}/pongo_abelii.fa"              "${NT}/pongo_chr_names.tsv"
reg nomascus    "Nomascus leucogenys" ""              "${CG}/nomascus.fa"                 "${NT}/nomascus_chr_names.tsv"
# ── catarrhine continuation (accession resolved by taxon; genome downloaded) ─
reg pongo_pyg     "Pongo pygmaeus"          "" "${CG}/pongo_pyg.fa"     "${NT}/pongo_pyg_chr_names.tsv"
reg symphalangus  "Symphalangus syndactylus" "" "${CG}/symphalangus.fa" "${NT}/symphalangus_chr_names.tsv"
reg mfascicularis "Macaca fascicularis"     "" "${CG}/mfascicularis.fa" "${NT}/mfascicularis_chr_names.tsv"
reg papio         "Papio anubis"            "" "${CG}/papio.fa"         "${NT}/papio_chr_names.tsv"
reg mmulatta      "Macaca mulatta"          "" "${CG}/mmulatta.fa"      "${NT}/mmulatta_chr_names.tsv"
reg rhinopithecus "Rhinopithecus roxellana" "" "${CG}/rhinopithecus.fa" "${NT}/rhinopithecus_chr_names.tsv"
reg callithrix    "Callithrix jacchus"      "" "${CG}/callithrix.fa"    "${NT}/callithrix_chr_names.tsv"

fetch_names(){ # <accession> <out>
  [ -s "$2" ] && return 0
  datasets summary genome accession "$1" --report sequence --as-json-lines 2>/dev/null \
    | jq -rc 'select(.role=="assembled-molecule") | .chr_name as $n
              | (.refseq_accession, .genbank_accession)
              | select(. != null and . != "") | [., $n] | @tsv' > "$2"
}

ensure(){ # <key>
  local k="$1"; local acc="${ACC[$k]}" zip extract fna
  if [ ! -s "${FA[$k]}" ]; then
    if [ -z "$acc" ]; then
      log "resolving reference accession for ${LBL[$k]}"
      acc=$(datasets summary genome taxon "${LBL[$k]}" --reference --as-json-lines 2>/dev/null \
            | jq -r '.accession // .current_accession // empty' | head -1)
      [ -n "$acc" ] || { log "FATAL: no accession for ${LBL[$k]}"; return 1; }
      ACC[$k]="$acc"
    fi
    log "downloading genome ${LBL[$k]} (${acc})"
    zip="${DL}/${k}.zip"; extract="${DL}/${k}"
    rm -rf "$extract"; mkdir -p "$extract"
    datasets download genome accession "$acc" --include genome --no-progressbar --filename "$zip" || return 1
    unzip -o -q "$zip" -d "$extract" || return 1
    fna=$(find "$extract" -name '*_genomic.fna' -o -name '*.fna' | sort | head -1)
    [ -n "$fna" ] || { log "FATAL: no FASTA in download for ${LBL[$k]}"; return 1; }
    cp -f "$fna" "${FA[$k]}"; rm -rf "$extract" "$zip"
  fi
  [ -s "${FA[$k]}.fai" ] || samtools faidx "${FA[$k]}"
  fetch_names "${ACC[$k]}" "${NM[$k]}"
  [ -s "${NM[$k]}" ] || { log "WARN: no name map for ${LBL[$k]}"; return 1; }
}

run_pair(){ # <ref_key> <query_key>   ref=bottom(y2), query=top(y1)
  local a="$1" b="$2" tag paf clean blocks fig
  tag="${a}__vs__${b}"
  paf="${OUT}/${tag}.paf"; clean="${OUT}/${tag}.clean.paf"
  blocks="${OUT}/${tag}.blocks.tsv"; fig="${OUT}/ribbon_${tag}.png"
  log "=== PAIR ${LBL[$a]} (ref) x ${LBL[$b]} (query) ==="
  ensure "$a" || { log "skip ${tag}: ${a} not ready"; return 1; }
  ensure "$b" || { log "skip ${tag}: ${b} not ready"; return 1; }
  if [ ! -s "$paf" ] || [ "${CGV_FORCE_ALIGN:-0}" = 1 ]; then
    log "minimap2 -cx asm20 (t=${THREADS}) ..."
    minimap2 -cx asm20 --cs -t "${THREADS}" "${FA[$a]}" "${FA[$b]}" > "${paf}.tmp" 2>"${OUT}/${tag}.mm2.log" \
      && mv -f "${paf}.tmp" "${paf}" || { log "minimap2 failed for ${tag}"; return 1; }
  fi
  awk -F'\t' '/tp:A:P/ && $12>=30 && $11>=100000' "${paf}" > "${clean}"
  { printf '#aligner\thuman_chr\th_start\th_end\tbonobo_chr\tb_start\tb_end\tstrand\tidentity_pct\n'
    cgv_norm_paf minimap2 "${clean}" 0 0; } > "${blocks}"
  log "$(grep -vc '^#' "${blocks}") filtered blocks -> ribbon"
  python3 "${SD}/cgv_ribbon.py" --blocks "${blocks}" --source minimap2 \
    --human-fai "${FA[$a]}.fai" --bonobo-fai "${FA[$b]}.fai" \
    --human-names "${NM[$a]}" --bonobo-names "${NM[$b]}" \
    --bottom-label "${LBL[$a]}" --top-label "${LBL[$b]}" \
    --min-bp 300000 --merge-gap 2000000 --alpha 0.8 --curve 0.5 --figw 24 \
    --title "${LBL[$a]} (y2) x ${LBL[$b]} (y1) — minimap2 primary/MAPQ30/100kb" \
    --out "${fig}" && log "FIGURE -> ${fig}" || log "ribbon failed for ${tag}"
}

# ── hominoid pair list (ref query) ─────────────────────────────────────────
PAIRS=(
  "human troglodytes"
  "human paniscus"
  "troglodytes paniscus"
  "troglodytes gorilla"
  "paniscus gorilla"
  "paniscus pongo"
  "gorilla pongo"
  "gorilla nomascus"
)
# allow running a subset: cgv_run_pairs.sh "ref query" ["ref query" ...]
(( $# > 0 )) && PAIRS=("$@")

log "running ${#PAIRS[@]} pair(s); threads=${THREADS}"
for p in "${PAIRS[@]}"; do run_pair $p; done
log "done. figures in ${OUT}/"
ls -1 "${OUT}"/ribbon_*.png 2>/dev/null >&2 || true
