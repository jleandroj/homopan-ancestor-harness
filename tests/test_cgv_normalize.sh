#!/usr/bin/env bash
# test_cgv_normalize.sh -- golden tests for the CGV sub-harness truth normalizer.
#
# Locks the two behaviours that previously broke and were only caught by hand:
#   1. RELATIVE STRAND = feature-strand (GFF col 7, human) x Target-strand
#      (bonobo): same sign -> "+", opposite -> "-". Using the Target strand
#      alone is wrong and silently inverts ~half the calls.
#   2. Coordinate normalization to 0-based half-open on both axes; identity from
#      pct_identity_gap.
#
# Fully isolated: copies the two scripts into a temp PROJECT_ROOT and feeds a
# synthetic GFF via CGV_TRUTH_GFF, so the real cgv_truth/ is never touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${HERE}/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cgv_norm.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/scripts"
cp "${SRC}/scripts/cgv_config.sh" "${SRC}/scripts/cgv_01_normalize_truth.sh" "${TMP}/scripts/"

# Synthetic GFF: 4 match records covering every (col7, Target-strand) combo,
# plus one non-match line that must be ignored.
GFF="${TMP}/fixture.gff"
cat > "${GFF}" <<'EOF'
##gff-version 3
NC_060925.1	RefSeq	region	1	1000	.	+	.	ID=region0
NC_060925.1	RefSeq	match	101	200	.	+	.	ID=a;Target=NC_073249.2 501 600 +;pct_identity_gap=97.0
NC_060925.1	RefSeq	match	301	400	.	+	.	ID=b;Target=NC_073249.2 701 800 -;pct_identity_gap=95.5
NC_060925.1	RefSeq	match	501	600	.	-	.	ID=c;Target=NC_073249.2 901 1000 +;pct_identity_gap=96.1
NC_060925.1	RefSeq	match	701	800	.	-	.	ID=d;Target=NC_073249.2 1101 1200 -;pct_identity_gap=98.2
EOF

# Run the normalizer in the temp project.
OUT_LOG="${TMP}/run.log"
CGV_MODE=test CGV_TRUTH_GFF="${GFF}" bash "${TMP}/scripts/cgv_01_normalize_truth.sh" >"${OUT_LOG}" 2>&1
rc=$?
BLOCKS="${TMP}/cgv_truth/truth_blocks.tsv"

fail=0
check() { # <desc> <condition-already-evaluated rc via $?>
  if [[ "$1" == "0" ]]; then echo "  [PASS] $2"; else echo "  [FAIL] $2"; fail=1; fi
}

# 0. ran and produced output
[[ $rc -eq 0 && -s "${BLOCKS}" ]]; check "$?" "normalizer ran and wrote truth_blocks.tsv"
if [[ ! -s "${BLOCKS}" ]]; then echo "---- log ----"; cat "${OUT_LOG}"; exit 1; fi

# 1. exactly 4 data rows (region line ignored)
n=$(grep -vc '^#' "${BLOCKS}")
[[ "$n" == "4" ]]; check "$?" "exactly 4 blocks parsed (non-match ignored), got ${n}"

# helper: strand for a given human start (0-based)
strand_at() { awk -F'\t' -v s="$1" '$1=="ncbi" && $3==s {print $8}' "${BLOCKS}"; }

# 2. RELATIVE STRAND truth table (the regression that mattered)
[[ "$(strand_at 100)" == "+" ]]; check "$?" "col7=+ , Target=+  => forward (+)"
[[ "$(strand_at 300)" == "-" ]]; check "$?" "col7=+ , Target=-  => reverse (-)"
[[ "$(strand_at 500)" == "-" ]]; check "$?" "col7=- , Target=+  => reverse (-)"
[[ "$(strand_at 700)" == "+" ]]; check "$?" "col7=- , Target=-  => forward (+)"

# 3. coordinate normalization (0-based half-open) for record 'a'
row_a=$(awk -F'\t' '$1=="ncbi" && $3==100' "${BLOCKS}")
[[ "$(echo "$row_a" | cut -f4)" == "200" ]]; check "$?" "human end is GFF end (200)"
[[ "$(echo "$row_a" | cut -f5)" == "NC_073249.2" ]]; check "$?" "bonobo chr from Target"
[[ "$(echo "$row_a" | cut -f6)" == "500" ]]; check "$?" "bonobo start 0-based (501-1=500)"
[[ "$(echo "$row_a" | cut -f7)" == "600" ]]; check "$?" "bonobo end (600)"
[[ "$(echo "$row_a" | cut -f9)" == "97.0" ]]; check "$?" "identity from pct_identity_gap (97.0)"

# 4. strand split sanity: 2 forward / 2 reverse
f=$(awk -F'\t' '$1=="ncbi" && $8=="+"' "${BLOCKS}" | wc -l)
r=$(awk -F'\t' '$1=="ncbi" && $8=="-"' "${BLOCKS}" | wc -l)
[[ "$f" == "2" && "$r" == "2" ]]; check "$?" "strand split 2+/2- (got ${f}+/${r}-)"

echo ""
if (( fail == 0 )); then echo "test_cgv_normalize: ALL PASS"; exit 0
else echo "test_cgv_normalize: FAILED"; exit 1; fi
