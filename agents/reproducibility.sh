#!/usr/bin/env bash
# ReproducibilityAgent -- a result that cannot be repeated is NOT evidence.
# Proves harness determinism via the mock toolchain (scripts/repro_verify.sh
# --mock) when available; otherwise reports NOT_REPRODUCIBLE/NOT_TESTED honestly.
# Also honors the documented fact that real Cactus is NOT bit-reproducible.
source "$(dirname "${BASH_SOURCE[0]}")/lib_verdict.sh"
verdict_init "ReproducibilityAgent"

if [[ -x "${ROOT}/scripts/repro_verify.sh" ]]; then
  if timeout 300 bash "${ROOT}/scripts/repro_verify.sh" --mock >/dev/null 2>&1; then
    check harness_determinism PASS "scripts/repro_verify.sh --mock" "harness injects no randomness (byte-identical on mock toolchain)"
  else
    check harness_determinism NOT_REPRODUCIBLE "scripts/repro_verify.sh --mock" "mock determinism check did not pass"
  fi
else
  check harness_determinism NOT_TESTED "" "repro_verify.sh not present"
fi

# documented scientific caveat: real Cactus alignment is NOT bit-reproducible
if grep -qi 'not.*bit-reprodu\|NOT bit-reproducible\|non-deterministic' "${ROOT}/REPRODUCIBILITY.md" 2>/dev/null; then
  check cactus_alignment NOT_REPRODUCIBLE "REPRODUCIBILITY.md" "real Cactus is multi-threaded/seedless -> ancestors are INFERRED, not reproducible byte-for-byte"
else
  check cactus_alignment NOT_TESTED "" "no reproducibility policy doc"
fi

# CGV minimap2 pairwise: deterministic given fixed inputs+version? (single-thread
# chaining order can vary; we mark EXPLORATORY unless a replay was compared)
if ls "${ROOT}"/results/cgv/pairs/*.blocks.tsv >/dev/null 2>&1; then
  check cgv_pairs EXPLORATORY_ONLY "results/cgv/pairs/*.blocks.tsv" "minimap2 pairwise: no replay-comparison recorded -> exploratory until repeated"
else
  check cgv_pairs NOT_TESTED "" "no CGV pairwise results"
fi
verdict_emit "reproducibility"
