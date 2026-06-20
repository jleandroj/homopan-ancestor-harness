#!/usr/bin/env bash
# test_cgv_paf_normalize.sh -- golden tests for aligner-output normalization
# (scripts/cgv_normalize.sh). Pure awk, no aligner binaries -> CI-safe.
#
# Locks the bugs that previously bit by hand:
#   * minimap2 identity from de:f (gap-compressed divergence -> percent)
#   * mashmap identity from id:f reported as a FRACTION -> x100
#   * box offsets added back to chromosome space on BOTH axes
#   * PAF axis mapping: target=human(6,8,9), query=bonobo(1,3,4), strand=5
#   * lastz id% strip and offset
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "${HERE}/.." && pwd)/scripts/cgv_normalize.sh"

fail=0
ck() { if [[ "$1" == "$2" ]]; then echo "  [PASS] $3"; else echo "  [FAIL] $3 (got '$1', want '$2')"; fail=1; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cgv_paf.XXXXXX")"; trap 'rm -rf "${TMP}"' EXIT

# ── minimap2 PAF: 1 forward block, de:f tag, with box offsets 10000/500000 ──
# query(bonobo) qlen qs qe strand target(human) tlen ts te nmatch blocklen mapq de:f
printf 'NC_073249.2\t1000\t100\t300\t+\tNC_060925.1\t2000\t200\t400\t190\t200\t60\tde:f:0.0100\n' > "${TMP}/mm.paf"
out=$(cgv_norm_paf minimap2 "${TMP}/mm.paf" 10000 500000)
ck "$(echo "$out" | wc -l)" "1" "minimap2: one row out"
ck "$(echo "$out" | cut -f1)" "minimap2" "minimap2: aligner tag"
ck "$(echo "$out" | cut -f2)" "NC_060925.1" "minimap2: human chr = PAF target"
ck "$(echo "$out" | cut -f3)" "10200" "minimap2: h_start = ts(200)+h_off(10000)"
ck "$(echo "$out" | cut -f4)" "10400" "minimap2: h_end = te(400)+h_off"
ck "$(echo "$out" | cut -f5)" "NC_073249.2" "minimap2: bonobo chr = PAF query"
ck "$(echo "$out" | cut -f6)" "500100" "minimap2: b_start = qs(100)+b_off(500000)"
ck "$(echo "$out" | cut -f8)" "+" "minimap2: strand"
ck "$(echo "$out" | cut -f9)" "99.0000" "minimap2: identity = (1-de)*100 = 99.0"

# minimap2 fallback when no de:f -> nmatch/blocklen*100
printf 'q\t1\t0\t10\t-\th\t1\t0\t10\t8\t10\t60\n' > "${TMP}/mm2.paf"
ck "$(cgv_norm_paf minimap2 "${TMP}/mm2.paf" 0 0 | cut -f9)" "80.0000" "minimap2: fallback nmatch/blocklen"

# ── mashmap PAF: id:f as a FRACTION (0.95 -> 95.0), reverse strand ──────────
printf 'NC_073249.2\t1000\t0\t5000\t-\tNC_060925.1\t2000\t10\t5010\t1\t5000\t8\tid:f:0.9500\tkc:f:0.1\n' > "${TMP}/ms.paf"
out=$(cgv_norm_paf mashmap "${TMP}/ms.paf" 0 0)
ck "$(echo "$out" | cut -f1)" "mashmap" "mashmap: aligner tag"
ck "$(echo "$out" | cut -f8)" "-" "mashmap: reverse strand"
ck "$(echo "$out" | cut -f9)" "95.0000" "mashmap: id:f fraction scaled x100"

# ── lastz general: id% strip + offsets ─────────────────────────────────────
# name1 zstart1 end1 name2 strand2 zstart2+ end2+ id%
printf '#header line ignored\n' > "${TMP}/lz.tsv"
printf 'NC_060925.1\t100\t200\tNC_073249.2\t-\t300\t400\t97.5%%\n' >> "${TMP}/lz.tsv"
out=$(cgv_norm_lastz "${TMP}/lz.tsv" 10000 500000)
ck "$(echo "$out" | wc -l)" "1" "lastz: header skipped, one row"
ck "$(echo "$out" | cut -f1)" "lastz" "lastz: aligner tag"
ck "$(echo "$out" | cut -f3)" "10100" "lastz: h_start + offset"
ck "$(echo "$out" | cut -f6)" "500300" "lastz: b_start + offset"
ck "$(echo "$out" | cut -f8)" "-" "lastz: strand"
ck "$(echo "$out" | cut -f9)" "97.5" "lastz: id% stripped"

echo ""
if (( fail == 0 )); then echo "test_cgv_paf_normalize: ALL PASS"; exit 0
else echo "test_cgv_paf_normalize: FAILED"; exit 1; fi
