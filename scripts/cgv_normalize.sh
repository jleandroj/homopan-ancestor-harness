#!/usr/bin/env bash
# cgv_normalize.sh -- single source of truth for aligner-output normalization.
#
# Converts each aligner's native output into the common blocks schema:
#   aligner human_chr h_start h_end bonobo_chr b_start b_end strand identity_pct
# 0-based half-open on both axes; human = target (X), bonobo = query (Y). Box
# offsets (test mode) are added so coordinates land in chromosome space.
#
# Pure (awk only, no external binaries, no side effects) so it is sourced by the
# aligner steps AND unit-tested in isolation (tests/test_cgv_paf_normalize.sh).
# Each function emits DATA ROWS ONLY (no header); callers prepend the header.

# PAF normalizer for minimap2 / mashmap.
#   minimap2: gap-compressed identity from the de:f tag.
#   mashmap : identity from the id:f tag, reported as a FRACTION (0..1) -> x100;
#             dv:f divergence as a secondary source.
#   fallback: residue-matches / block-length (cols 10/11).
# PAF layout: query=1,3,4 (bonobo); strand=5; target=6,8,9 (human).
cgv_norm_paf() {   # <aligner: minimap2|mashmap> <paf_file> [h_offset] [b_offset]
  local aligner="$1" paf="$2" ho="${3:-0}" bo="${4:-0}"
  awk -F'\t' -v al="${aligner}" -v ho="${ho}" -v bo="${bo}" '
    /^#/ { next }
    NF>=11 {
      qn=$1; qs=$3; qe=$4; st=$5; tn=$6; ts=$8; te=$9; nm=$10; bl=$11;
      id="";
      for(i=12;i<=NF;i++){
        if(al=="minimap2" && $i ~ /^de:f:/)            id=(1-substr($i,6))*100;
        else if(al=="mashmap"  && $i ~ /^id:f:/)        id=substr($i,6)*100;
        else if(al=="mashmap"  && $i ~ /^dv:f:/ && id=="") id=(1-substr($i,6))*100;
      }
      if(id=="") id=(bl>0 ? nm/bl*100 : 0);
      printf "%s\t%s\t%d\t%d\t%s\t%d\t%d\t%s\t%.4f\n", al, tn, ts+ho, te+ho, qn, qs+bo, qe+bo, st, id;
    }' "${paf}"
}

# LASTZ general-format normalizer.
# Raw cols: name1 zstart1 end1 name2 strand2 zstart2+ end2+ id%
#   name1/zstart1/end1 = human (0-based half-open); name2/zstart2+/end2+ = bonobo.
cgv_norm_lastz() {   # <general_tsv> [h_offset] [b_offset]
  awk -F'\t' -v ho="${2:-0}" -v bo="${3:-0}" '
    /^#/ { next }
    {
      hchr=$1; hs=$2; he=$3; bchr=$4; st=$5; bs=$6; be=$7; id=$8;
      gsub(/%/,"",id);
      printf "lastz\t%s\t%d\t%d\t%s\t%d\t%d\t%s\t%s\n", hchr, hs+ho, he+ho, bchr, bs+bo, be+bo, st, id;
    }' "$1"
}
