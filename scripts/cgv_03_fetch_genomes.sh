#!/usr/bin/env bash
# cgv_03_fetch_genomes.sh -- Make the two assemblies available with RefSeq NC_*
# headers that match the official GFF exactly.
#
#   HUMAN  : downloaded fresh from NCBI Datasets (GCF_009914755.1) so the version
#            and headers match the GFF (the local human FASTA is GenBank
#            GCA_009914755.4 with CP068* headers -> wrong namespace / possible
#            version drift, so we do NOT reuse it).
#   BONOBO : the local genomes/pan_paniscus.fa IS GCF_029289425.2 with the exact
#            RefSeq NC_073* headers used by the GFF -> reused as-is (no 3 GB
#            re-download). Force a fresh download with CGV_FORCE_DOWNLOAD=1.
#
# NOTE: NCBI Datasets `--chromosomes` does NOT slice a monolithic genomic FASTA,
# so we fetch the full assembly once and extract chromosomes with samtools faidx.
# Egress goes to NCBI (already in egress_allowlist.txt); `datasets` does its own
# HTTPS (curl/wget/WebFetch are deny-listed, this tool is not).
source "$(dirname "${BASH_SOURCE[0]}")/cgv_config.sh"

cgv_banner "CGV step 03 -- fetch genomes (mode=${CGV_MODE})"
cgv_require_tool datasets
cgv_require_tool samtools
cgv_require_tool unzip
mkdir -p "${CGV_GENOMES_DIR}" "${CGV_TEST_DIR}"

LOCAL_BONOBO="${PROJECT_ROOT}/genomes/pan_paniscus.fa"
DL_TMP="${CGV_GENOMES_DIR}/.download"; mkdir -p "${DL_TMP}"

# Download a FULL assembly genomic FASTA to $out (idempotent on $out).
fetch_full_assembly() {   # <assembly_acc> <out_fasta>
  local acc="$1" out="$2"
  if [[ -s "${out}" && "${CGV_FORCE_DOWNLOAD:-0}" != "1" ]]; then
    log_ok "Reusing existing $(basename "${out}") ($(du -h "${out}" | cut -f1)); CGV_FORCE_DOWNLOAD=1 to re-fetch."
    return 0
  fi
  local zip="${DL_TMP}/${acc}.zip" extract="${DL_TMP}/${acc}"
  rm -rf "${extract}"; mkdir -p "${extract}"
  log_step "datasets download genome accession ${acc} --include genome (full assembly)"
  datasets download genome accession "${acc}" --include genome --no-progressbar --filename "${zip}" \
    || die "datasets download failed for ${acc}"
  unzip -o -q "${zip}" -d "${extract}" || die "unzip failed for ${zip}"
  local fnas=()
  while IFS= read -r f; do fnas+=("$f"); done < <(find "${extract}" -name '*_genomic.fna' -o -name '*.fna' | sort)
  (( ${#fnas[@]} > 0 )) || die "No genomic FASTA in download for ${acc} (got only metadata?)."
  cat "${fnas[@]}" > "${out}.tmp" && mv -f "${out}.tmp" "${out}"
  rm -f "${zip}"; rm -rf "${extract}"
  log_ok "Downloaded ${acc} -> $(basename "${out}") ($(du -h "${out}" | cut -f1))"
}

# ── Human: always fresh from NCBI ──────────────────────────────────────────
fetch_full_assembly "${HUMAN_ACC}" "${HUMAN_FA}"
samtools faidx "${HUMAN_FA}"

# ── Bonobo: reuse the exact local GCF unless forced ───────────────────────
if [[ "${CGV_FORCE_DOWNLOAD:-0}" == "1" ]]; then
  fetch_full_assembly "${BONOBO_ACC}" "${BONOBO_FA}"
  samtools faidx "${BONOBO_FA}"
elif [[ -s "${LOCAL_BONOBO}" ]]; then
  [[ -s "${LOCAL_BONOBO}.fai" ]] || samtools faidx "${LOCAL_BONOBO}"
  ln -sf "${LOCAL_BONOBO}" "${BONOBO_FA}"
  ln -sf "${LOCAL_BONOBO}.fai" "${BONOBO_FA}.fai"
  log_ok "Reusing local bonobo (exact ${BONOBO_ACC}): $(basename "${LOCAL_BONOBO}")"
else
  fetch_full_assembly "${BONOBO_ACC}" "${BONOBO_FA}"
  samtools faidx "${BONOBO_FA}"
fi

# ── Test mode: extract the selected chromosome pair ───────────────────────
if [[ "${CGV_MODE}" == "test" ]]; then
  [[ -s "${REGION_FILE}" ]] || die "Region file missing; run cgv_02 first: ${REGION_FILE}"
  human_acc=$(awk -F'\t' '$1=="human"{print $2}'  "${REGION_FILE}")
  bonobo_acc=$(awk -F'\t' '$1=="bonobo"{print $2}' "${REGION_FILE}")
  grep -q -m1 "^${human_acc}"$'\t' "${HUMAN_FA}.fai"  || die "Human contig ${human_acc} not in downloaded ${HUMAN_ACC}."
  grep -q -m1 "^${bonobo_acc}"$'\t' "${BONOBO_FA}.fai" || die "Bonobo contig ${bonobo_acc} not in ${BONOBO_ACC}."

  # Extract the homologous BOX on BOTH genomes (faidx is 1-based inclusive).
  # Rename each header back to the bare accession so the chromosome name matches
  # the truth; coordinates start at 1 (= box start) and are shifted back to
  # chromosome space later via the recorded offsets.
  Hs=$(cgv_region_get human_start 0);  He=$(cgv_region_get human_end 0)
  Bs=$(cgv_region_get bonobo_start 0); Be=$(cgv_region_get bonobo_end 0)
  hlen=$(awk -F'\t' -v a="${human_acc}"  '$1==a{print $2}' "${HUMAN_FA}.fai")
  blen=$(awk -F'\t' -v a="${bonobo_acc}" '$1==a{print $2}' "${BONOBO_FA}.fai")
  (( He > hlen )) && He=${hlen}
  (( Be > blen )) && Be=${blen}
  log_step "Extracting homologous box: human ${human_acc}:$((Hs+1))-${He}  bonobo ${bonobo_acc}:$((Bs+1))-${Be}"
  samtools faidx "${HUMAN_FA}"  "${human_acc}:$((Hs+1))-${He}" \
    | awk -v a="${human_acc}"  'NR==1{print ">"a; next}{print}' > "${HUMAN_TEST_FA}.tmp"  && mv -f "${HUMAN_TEST_FA}.tmp"  "${HUMAN_TEST_FA}"
  samtools faidx "${BONOBO_FA}" "${bonobo_acc}:$((Bs+1))-${Be}" \
    | awk -v a="${bonobo_acc}" 'NR==1{print ">"a; next}{print}' > "${BONOBO_TEST_FA}.tmp" && mv -f "${BONOBO_TEST_FA}.tmp" "${BONOBO_TEST_FA}"
  samtools faidx "${HUMAN_TEST_FA}"
  samtools faidx "${BONOBO_TEST_FA}"
  log_ok "Test FASTAs (box): $(basename "${HUMAN_TEST_FA}") ($(cut -f2 "${HUMAN_TEST_FA}.fai") bp) + $(basename "${BONOBO_TEST_FA}") ($(cut -f2 "${BONOBO_TEST_FA}.fai") bp)"
fi

rmdir "${DL_TMP}" 2>/dev/null || true
log_ok "Genomes ready for mode=${CGV_MODE}."
