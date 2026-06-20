#!/usr/bin/env bash
# test_resume.sh -- P1.6: a pipeline that fails mid-way RESUMES on re-run, skipping
# already-completed steps (idempotency markers), not redoing them. First run fails
# at step 04 (mock cactus forced to exit 1); second run succeeds and must SKIP
# 00-03 (their markers' mtimes unchanged) while completing 04+.
set -uo pipefail
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok(){ echo "  [PASS] $1"; pass=$((pass+1)); }
no(){ echo "  [FAIL] $1"; fail=$((fail+1)); }
command -v samtools >/dev/null 2>&1 || { echo "  [SKIP] host samtools missing"; exit 0; }

SPECIES=(homo_sapiens pan_paniscus pan_troglodytes gorilla_gorilla_gorilla pongo_abelii)
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/scripts" "${TMP}/genomes" "${TMP}/bin"
cp "${SRC_ROOT}/scripts/"*.sh "${TMP}/scripts/"
printf 'species\taccession\n' > "${TMP}/accessions.tsv"
: > "${TMP}/cactus_v3.0.1.sif"
for sp in "${SPECIES[@]}"; do
  { echo ">chr_${sp}"; yes "ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTAC" | head -n 40; } > "${TMP}/genomes/${sp}.fa"
  samtools faidx "${TMP}/genomes/${sp}.fa" 2>/dev/null
done

# Stub apptainer; cactus fails when HOMOPAN_TEST_FAIL_CACTUS=1.
cat > "${TMP}/bin/apptainer" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "apptainer version 1.0.0-mock"; exit 0; }
args=("$@"); [[ "${args[0]:-}" == "exec" ]] && args=("${args[@]:1}")
i=0; while (( i < ${#args[@]} )); do case "${args[$i]}" in
  --bind) i=$((i+2));; *.sif) i=$((i+1)); break;; --*) i=$((i+1));; *) break;; esac; done
tool="${args[$i]:-}"; rest=("${args[@]:$((i+1))}")
case "$tool" in
  which) echo "/usr/local/bin/${rest[0]:-x}"; exit 0;;
  cactus)
    for a in "${rest[@]}"; do [[ "$a" == "--version" ]] && { echo "9.1.2-mock"; exit 0; }; done
    for a in "${rest[@]}"; do [[ "$a" == "--help" ]] && { echo "options: --binariesMode --retryCount --seed"; exit 0; }; done
    [[ "${HOMOPAN_TEST_FAIL_CACTUS:-0}" == "1" ]] && { echo "mock cactus forced failure" >&2; exit 1; }
    pos=(); j=0; while (( j < ${#rest[@]} )); do case "${rest[$j]}" in
      --binariesMode|--batchSystem|--realTimeLogging|--retryCount|--seed|--consCores|--lastzCores|--maxCores) j=$((j+2));;
      --*) j=$((j+1));; *) pos+=("${rest[$j]}"); j=$((j+1));; esac; done
    hal="${pos[2]:-}"; [[ -n "$hal" ]] || { echo "no hal" >&2; exit 1; }
    mkdir -p "$(dirname "$hal")"; printf 'MOCK-HAL\n' > "$hal"; exit 0;;
  halValidate) echo "File valid"; exit 0;;
  halStats) case "${rest[0]:-}" in
      --genomes) echo "homo_sapiens, pan_paniscus, pan_troglodytes, gorilla_gorilla_gorilla, pongo_abelii, Anc_HomoPan, Pan, Homininae, Root";;
      --tree) echo "(((homo_sapiens,(pan_paniscus,pan_troglodytes)Pan)Anc_HomoPan,gorilla_gorilla_gorilla)Homininae,pongo_abelii)Root;";;
      --genomeLength) echo "2000";; *) echo "mock halStats";; esac; exit 0;;
  hal2fasta) printf '>%s\nACGTACGTACGTACGTACGTACGTACGTACGT\n' "${rest[1]:-anc}"; exit 0;;
  *) exit 0;;
esac
STUB
chmod +x "${TMP}/bin/apptainer"

run(){ # <fail_cactus 0|1>
  PATH="${TMP}/bin:${PATH}" CACTUS_TIMEOUT=60 HOMOPAN_SKIP_PREFLIGHT=1 \
    HOMOPAN_IGNORE_TOOLCHAIN_LOCK=1 HOMOPAN_SANDBOX_COMPUTE=0 HOMOPAN_STEP_RETRIES=0 \
    HOMOPAN_TEST_FAIL_CACTUS="$1" \
    bash "${TMP}/scripts/run_all_test.sh" >"${TMP}/run_$1.log" 2>&1
}
mark="${TMP}/targets"
mtimes(){ for s in "$@"; do [[ -f "${mark}/${s}.done" ]] && stat -c '%Y' "${mark}/${s}.done" || echo missing; done; }

echo "resume after mid-pipeline failure (P1.6)"
echo "════════════════════════════════════════"

# ── Run 1: cactus fails -> pipeline aborts at 04; 00-03 marked done ─────────
if run 1; then no "run 1 should FAIL at cactus but succeeded"; else ok "run 1 fails at cactus (as designed)"; fi
pre_steps=(00_check_env 01_validate_fastas 02_make_test_fastas 03_make_seqfiles)
allpre=1; for s in "${pre_steps[@]}"; do [[ -f "${mark}/${s}.done" ]] || { allpre=0; echo "      missing: ${s}"; }; done
(( allpre )) && ok "pre-cactus steps 00-03 marked done after failure" || no "00-03 markers missing after run 1"
[[ -f "${mark}/04_run_test_cactus.done" ]] && no "04 marker present despite failure" || ok "04 NOT marked done (failed step left no marker)"

before="$(mtimes "${pre_steps[@]}")"
sleep 1   # ensure any re-run would change mtime

# ── Run 2: cactus succeeds -> resume; 00-03 SKIPPED, pipeline completes ─────
if run 0; then ok "run 2 completes (resumed)"; else no "run 2 should complete but failed"; sed 's/^/      /' "${TMP}/run_0.log" | tail -15; fi
after="$(mtimes "${pre_steps[@]}")"
[[ "${before}" == "${after}" ]] && ok "00-03 markers UNCHANGED on re-run (skipped, not redone)" \
  || no "00-03 markers changed on re-run (steps were re-executed): before=[${before}] after=[${after}]"
[[ -f "${mark}/04_run_test_cactus.done" ]] && ok "04 now marked done after resume" || no "04 still not done after run 2"
[[ -f "${mark}/05_validate_test_hal.done" ]] && ok "05 ran after resume" || no "05 did not run after resume"
grep -qiE 'skip|already (done|complete)|up.to.date' "${TMP}/run_0.log" && ok "run 2 log shows steps skipped" \
  || echo "  [INFO] run 2 log has no explicit skip line (mtime check is authoritative)"

echo ""
echo "  Results: ${pass} passed, ${fail} failed"
(( fail == 0 )) && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
