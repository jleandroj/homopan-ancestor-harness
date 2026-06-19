#!/usr/bin/env bash
# 02_make_test_fastas.sh -- Create 1 Mb test FASTAs using samtools (NOT seqkit)
# Strategy: find ONE offset that gives <60% softmasking for ALL species,
# so the test regions are homologous across species (same chr1 window).
set -euo pipefail
source "$(dirname "$0")/config.sh"

script_banner "02 - Make Test FASTAs (${TEST_REGION_LEN} bp)"

require_done "01_validate_fastas"

mkdir -p "${TEST_GENOMES_DIR}"

# Maximum acceptable softmasked fraction for a test region
MAX_MASKED_FRAC=0.60

# ── Phase 1: Find a single offset that works for ALL species ──────────────
# We scan candidate offsets and for each, check softmasking in ALL species.
# This ensures the test extracts homologous regions (same position on chr1).

CANDIDATE_OFFSETS=(0 10000000 20000000 30000000 50000000 100000000 150000000)
BEST_OFFSET=""

check_masked_frac() {
  local fa="$1" seq_name="$2" start="$3" end="$4"
  local total upper
  total=$(run_samtools faidx "${fa}" "${seq_name}:${start}-${end}" \
    | grep -v "^>" | tr -d '\n' | wc -c)
  upper=$(run_samtools faidx "${fa}" "${seq_name}:${start}-${end}" \
    | grep -v "^>" | tr -d '\n' | tr -d 'acgtn' | wc -c)
  if (( total == 0 )); then
    echo "1.000"
    return
  fi
  awk "BEGIN{printf \"%.3f\", 1 - ${upper}/${total}}"
}

log_step "Scanning for a shared offset with low masking in all species"

for offset in "${CANDIDATE_OFFSETS[@]}"; do
  start=$(( offset + 1 ))
  end=$(( offset + TEST_REGION_LEN ))
  all_ok=true
  log_info "Testing offset ${offset} (${start}-${end})..."

  for sp in "${SPECIES[@]}"; do
    FA="${GENOMES_DIR}/${sp}.fa"
    FAI="${FA}.fai"
    FIRST_SEQ=$(head -1 "${FAI}" | cut -f1)
    SEQ_LEN=$(head -1 "${FAI}" | cut -f2)

    # Skip if beyond sequence length
    if (( end > SEQ_LEN )); then
      log_info "  ${sp}: offset ${offset} beyond seq length ${SEQ_LEN} -- skip"
      all_ok=false
      break
    fi

    mf=$(check_masked_frac "${FA}" "${FIRST_SEQ}" "${start}" "${end}")
    if awk "BEGIN{exit !(${mf} >= ${MAX_MASKED_FRAC})}"; then
      log_info "  ${sp}: ${mf} masked -- too high"
      all_ok=false
      break
    else
      log_info "  ${sp}: ${mf} masked -- ok"
    fi
  done

  if $all_ok; then
    BEST_OFFSET=${offset}
    log_ok "Offset ${offset} works for all species"
    break
  fi
done

if [[ -z "${BEST_OFFSET}" ]]; then
  log_warn "No shared offset found with <${MAX_MASKED_FRAC} masking for all species"
  log_warn "Falling back to per-species offset selection"
  BEST_OFFSET="per_species"
fi

# ── Phase 2: Extract test FASTAs ──────────────────────────────────────────

for sp in "${SPECIES[@]}"; do
  FA="${GENOMES_DIR}/${sp}.fa"
  FAI="${FA}.fai"
  TEST_FA="${TEST_GENOMES_DIR}/${sp}.test1Mb.fa"

  log_step "Creating test FASTA for ${sp}"

  FIRST_SEQ=$(head -1 "${FAI}" | cut -f1)
  SEQ_LEN=$(head -1 "${FAI}" | cut -f2)

  if (( SEQ_LEN < TEST_REGION_LEN )); then
    log_warn "${sp}: first seq ${FIRST_SEQ} is only ${SEQ_LEN} bp (< ${TEST_REGION_LEN})"
    EXTRACT_LEN=${SEQ_LEN}
    START=1
  else
    EXTRACT_LEN=${TEST_REGION_LEN}
    if [[ "${BEST_OFFSET}" == "per_species" ]]; then
      # Fallback: per-species scan
      START=1
      for offset in "${CANDIDATE_OFFSETS[@]}"; do
        s=$(( offset + 1 ))
        e=$(( offset + EXTRACT_LEN ))
        (( e <= SEQ_LEN )) || continue
        mf=$(check_masked_frac "${FA}" "${FIRST_SEQ}" "$s" "$e")
        if awk "BEGIN{exit !(${mf} < ${MAX_MASKED_FRAC})}"; then
          START=$s
          break
        fi
      done
    else
      START=$(( BEST_OFFSET + 1 ))
    fi
  fi

  END=$(( START + EXTRACT_LEN - 1 ))

  # Extract region using samtools faidx
  # samtools faidx adds ":start-end" suffix to header -- strip it with sed
  # Use | delimiter to avoid conflicts with / or & in sequence names
  run_samtools faidx "${FA}" "${FIRST_SEQ}:${START}-${END}" \
    | sed "s|^>.*|>${FIRST_SEQ}|" \
    > "${TEST_FA}"

  # Index the test FASTA
  run_samtools faidx "${TEST_FA}"

  # Verify
  TEST_BP=$(awk '{sum+=$2}END{print sum}' "${TEST_FA}.fai")
  log_ok "${sp}: test FASTA = ${TEST_BP} bp from ${FIRST_SEQ}:${START}-${END}"
done

log_ok "Test FASTAs created in $(sanitize_path "${TEST_GENOMES_DIR}")"
mark_done "02_make_test_fastas"
