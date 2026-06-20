#!/usr/bin/env bash
# test_cgv_box_filter.sh -- the test-mode BOX restriction in cgv_20_collect.sh.
# In test mode the ground truth must be restricted to the homologous box on BOTH
# axes (human [hs,he) AND bonobo [bs,be)); blocks outside, or on other
# chromosomes, must be dropped. Isolated temp project; awk/column only -> CI-safe.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cgv_box.XXXXXX")"; trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/scripts" "${TMP}/cgv_truth" "${TMP}/cgv_genomes/test" "${TMP}/results/cgv/test/blocks"
cp "${SRC}/scripts/cgv_config.sh" "${SRC}/scripts/cgv_normalize.sh" "${SRC}/scripts/cgv_20_collect.sh" "${TMP}/scripts/"

# Box: human NC_A [10000,20000) x bonobo NC_B [50000,60000)
cat > "${TMP}/cgv_genomes/test/region.tsv" <<'EOF'
#role	accession
human	NC_A
bonobo	NC_B
window_bp	10000
human_start	10000
human_end	20000
bonobo_start	50000
bonobo_end	60000
EOF

# Truth: 1 in-box + 3 that must be dropped (out by human, out by bonobo, wrong chr)
cat > "${TMP}/cgv_truth/truth_blocks.tsv" <<'EOF'
#aligner	human_chr	h_start	h_end	bonobo_chr	b_start	b_end	strand	identity_pct
ncbi	NC_A	12000	13000	NC_B	55000	56000	+	98.0
ncbi	NC_A	25000	26000	NC_B	55000	56000	+	97.0
ncbi	NC_A	15000	16000	NC_B	70000	71000	-	96.0
ncbi	NC_X	12000	13000	NC_B	55000	56000	+	95.0
EOF

# One aligner blocks file (in-box) so the collector also folds aligner rows in.
cat > "${TMP}/results/cgv/test/blocks/minimap2.blocks.tsv" <<'EOF'
#aligner	human_chr	h_start	h_end	bonobo_chr	b_start	b_end	strand	identity_pct
minimap2	NC_A	12100	12900	NC_B	55050	55900	+	98.4
EOF

CGV_MODE=test bash "${TMP}/scripts/cgv_20_collect.sh" >"${TMP}/run.log" 2>&1
rc=$?
ALL="${TMP}/results/cgv/test/all_blocks.tsv"
SUM="${TMP}/results/cgv/test/block_summary.tsv"

fail=0
ck() { if [[ "$1" == "$2" ]]; then echo "  [PASS] $3"; else echo "  [FAIL] $3 (got '$1', want '$2')"; fail=1; fi; }

[[ $rc -eq 0 && -s "${ALL}" && -s "${SUM}" ]]; if [[ $? -ne 0 ]]; then echo "  [FAIL] collector ran"; cat "${TMP}/run.log"; exit 1; fi
echo "  [PASS] collector ran and wrote outputs"

# Only the single in-box ncbi row survives
n_ncbi=$(awk -F'\t' '$1=="ncbi"' "${ALL}" | wc -l)
ck "${n_ncbi}" "1" "exactly 1 in-box truth row kept (3 dropped)"
kept=$(awk -F'\t' '$1=="ncbi"{print $3}' "${ALL}")
ck "${kept}" "12000" "kept row is the in-box one (h_start 12000)"

# The dropped ones are really gone
ck "$(awk -F'\t' '$1=="ncbi" && $3==25000' "${ALL}" | wc -l)" "0" "out-by-human row dropped"
ck "$(awk -F'\t' '$1=="ncbi" && $6==70000' "${ALL}" | wc -l)" "0" "out-by-bonobo row dropped"
ck "$(awk -F'\t' '$1=="ncbi" && $2=="NC_X"' "${ALL}" | wc -l)" "0" "wrong-chromosome row dropped"

# Aligner rows folded in unchanged
ck "$(awk -F'\t' '$1=="minimap2"' "${ALL}" | wc -l)" "1" "aligner row included"

# block_summary: ncbi count reflects the box restriction
ncbi_sum=$(awk -F'\t' '$1=="ncbi"{print $2}' "${SUM}")
ck "${ncbi_sum}" "1" "block_summary ncbi count = 1 (box-restricted)"

echo ""
if (( fail == 0 )); then echo "test_cgv_box_filter: ALL PASS"; exit 0
else echo "test_cgv_box_filter: FAILED"; cat "${TMP}/run.log"; exit 1; fi
