#!/usr/bin/env bash
# annotate_ancestral_provenance.sh
# ---------------------------------------------------------------------------
# Stamp ancestral genomes that were generated under the NON-DETERMINISTIC
# Cactus condition with a full provenance record. For each ancestral FASTA it
# writes a sidecar "<file>.provenance.json" (machine-readable) and refreshes a
# human-readable PROVENANCE.md + NON_DETERMINISTIC_WARNING.txt in the dir.
#
# WHY: verified 2026-06 that the container's Cactus 9.1.2 has NO RNG --seed and
# that cactus_consolidated runs multi-threaded by default, so the same inputs
# yield a DIFFERENT ancestral sequence each run (measured ancestral identity
# ~0.33 across two real runs). These genomes are INFERENCES, not canonical;
# every artifact must carry that fact with name, date, code version and method.
#
# The FASTA itself is left PRISTINE (sidecars are the genomics-standard way to
# attach metadata without breaking downstream parsers).
#
# Usage:  bash scripts/annotate_ancestral_provenance.sh [ancestors_dir] [run_id]
#   ancestors_dir  default: results/ancestors
#   run_id         optional label for the run that produced these genomes
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${1:-${ROOT}/results/ancestors}"
RUN_ID="${2:-${HOMOPAN_RUN_ID:-unknown}}"
LOCK="${ROOT}/repro/toolchain.lock"

[[ -d "${DIR}" ]] || { echo "ERROR: ancestors dir not found: ${DIR}" >&2; exit 1; }

now="$(date -Iseconds)"
git_commit="$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
git_dirty="$([[ -n "$(git -C "${ROOT}" status --porcelain 2>/dev/null)" ]] && echo true || echo false)"
host="$(hostname 2>/dev/null || echo unknown)"
cactus_v="$(grep -E '^strict_cactus=' "${LOCK}" 2>/dev/null | cut -d= -f2- || echo unknown)"
sif_sha="$(grep -E '^strict_sif_sha256=' "${LOCK}" 2>/dev/null | cut -d= -f2- || echo unknown)"

# Determinism status -- VERIFIED by probing the container (see DET_EVIDENCE).
DET_EVIDENCE="apptainer exec cactus_v3.0.1.sif cactus --help | grep -i seed => no --seed; cactus_consolidated -T/--threads default=all (multi-threaded, unseeded)"
HOWGEN="HomoPan pipeline (run_all_test.sh / run_all_full.sh) -> step 04/06 -> cactus -> cactus_consolidated; reference-free progressive alignment; ancestral sequence inferred at internal node, extracted via hal2fasta."
WARN="NON-DETERMINISTIC INFERENCE. Cactus ${cactus_v} has no RNG seed and runs multi-threaded; re-running identical inputs produces a DIFFERENT sequence (measured ancestral identity ~0.33 across two real runs, seed=0). This genome is an inference, NOT an observed or canonical sequence. Do not treat its bytes as reproducible."

have_jq=0; command -v jq >/dev/null 2>&1 && have_jq=1

shopt -s nullglob
declare -a SUMMARY=()
count=0
for fa in "${DIR}"/*.fa "${DIR}"/*.fasta; do
  [[ -f "${fa}" ]] || continue
  base="$(basename "${fa}")"
  sha="$(sha256sum "${fa}" | cut -d' ' -f1)"
  bytes="$(wc -c < "${fa}")"
  bp="$(grep -v '^>' "${fa}" 2>/dev/null | tr -d '\n' | wc -c)"
  ncount="$(grep -v '^>' "${fa}" 2>/dev/null | tr -cd 'Nn' | wc -c)"
  nfrac="$(awk -v n="${ncount}" -v b="${bp}" 'BEGIN{ if(b>0) printf "%.6f", n/b; else printf "NA" }')"
  gen_at="$(date -Iseconds -r "${fa}" 2>/dev/null || echo unknown)"
  out="${fa}.provenance.json"

  if (( have_jq )); then
    jq -n \
      --arg genome "${base}" --arg sha "${sha}" --arg bytes "${bytes}" --arg bp "${bp}" \
      --arg nfrac "${nfrac}" --arg gen_at "${gen_at}" --arg annot_at "${now}" \
      --arg run_id "${RUN_ID}" --arg commit "${git_commit}" --arg dirty "${git_dirty}" \
      --arg host "${host}" --arg cactus "${cactus_v}" --arg sif "${sif_sha}" \
      --arg howgen "${HOWGEN}" --arg evid "${DET_EVIDENCE}" --arg warn "${WARN}" \
      '{
        genome: $genome,
        sha256: $sha, bytes: ($bytes|tonumber), bp: ($bp|tonumber), n_fraction: $nfrac,
        generated_at: $gen_at, annotated_at: $annot_at, run_id: $run_id,
        code: { repo: "HomoPan_harness", git_commit: $commit, git_dirty: ($dirty=="true") },
        toolchain: { cactus_version: $cactus, sif_sha256: $sif, host: $host },
        how_generated: $howgen,
        determinism: {
          seed_supported: false, cactus_seed_active: false, multithreaded: true,
          reproducible: false, evidence: $evid
        },
        warning: $warn
      }' > "${out}"
  else
    printf '{"genome":"%s","sha256":"%s","bytes":%s,"bp":%s,"n_fraction":"%s","generated_at":"%s","annotated_at":"%s","run_id":"%s","code":{"git_commit":"%s","git_dirty":%s},"toolchain":{"cactus_version":"%s","sif_sha256":"%s","host":"%s"},"determinism":{"seed_supported":false,"cactus_seed_active":false,"multithreaded":true,"reproducible":false},"warning":"%s"}\n' \
      "${base}" "${sha}" "${bytes}" "${bp}" "${nfrac}" "${gen_at}" "${now}" "${RUN_ID}" \
      "${git_commit}" "${git_dirty}" "${cactus_v}" "${sif_sha}" "${host}" "${WARN}" > "${out}"
  fi
  echo "  [annotated] ${base}  (${bp} bp, sha ${sha:0:12}..., generated ${gen_at})"
  SUMMARY+=("| ${base} | ${bp} | ${gen_at} | ${sha:0:16}… | ${RUN_ID} |")
  count=$((count+1))
done

if (( count == 0 )); then
  echo "No ancestral FASTAs (*.fa/*.fasta) found in ${DIR}" >&2
  exit 1
fi

# Human-readable summary in the dir.
{
  echo "# Ancestral genome provenance (NON-DETERMINISTIC condition)"
  echo ""
  echo "> Annotated ${now} from code \`${git_commit:0:12}\` (dirty=${git_dirty}) on \`${host}\`."
  echo ""
  echo "**WARNING:** ${WARN}"
  echo ""
  echo "How generated: ${HOWGEN}"
  echo ""
  echo "Determinism evidence: \`${DET_EVIDENCE}\`"
  echo ""
  echo "| genome | bp | generated_at | sha256 | run_id |"
  echo "|---|---:|---|---|---|"
  printf '%s\n' "${SUMMARY[@]}"
  echo ""
  echo "Per-genome machine-readable records: \`<genome>.provenance.json\`."
} > "${DIR}/PROVENANCE.md"
printf '%s\n' "${WARN}" > "${DIR}/NON_DETERMINISTIC_WARNING.txt"

echo ""
echo "Annotated ${count} genome(s). Wrote sidecars + PROVENANCE.md + NON_DETERMINISTIC_WARNING.txt in ${DIR}"
