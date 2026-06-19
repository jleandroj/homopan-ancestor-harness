#!/usr/bin/env bash
# test_toolchain_lock.sh -- verify_toolchain_lock fails-closed on drift of an
# OUTPUT-DETERMINING (strict_*) tool, passes when the lock matches, and honors
# the HOMOPAN_IGNORE_TOOLCHAIN_LOCK override. Uses HOMOPAN_TOOLCHAIN_LOCK to
# point at throwaway lock files (never touches repro/toolchain.lock).
export HOMOPAN_RUN_NS="__test_lock_$$"
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SRC_ROOT}/scripts/config.sh" >/dev/null 2>&1
set +e
RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0
ok()  { echo -e "  ${GREEN}[PASS]${NC} $*"; ((PASS++)) || true; }
bad() { echo -e "  ${RED}[FAIL]${NC} $*"; ((FAIL++)) || true; }

TMP="$(mktemp -d)"
run_in_container() { echo "cactus 9.1.2-stub"; }   # cactus_version() -> 9.1.2
SIF="${TMP}/fake.sif"; : > "${SIF}"
SIF_SHA=$(sha256sum "${SIF}" | cut -d' ' -f1)
SAM="$(samtools --version 2>/dev/null | head -1)"
APP="$(apptainer --version 2>/dev/null)"

# Lock that MATCHES the observed (stubbed) toolchain.
cat > "${TMP}/ok.lock" <<EOF
schema=1
strict_sif_sha256=${SIF_SHA}
strict_cactus=9.1.2
strict_samtools=${SAM}
strict_apptainer=${APP}
audit_kernel=definitely-not-this-kernel
EOF
# Lock with a STRICT drift (samtools).
cat > "${TMP}/bad.lock" <<EOF
schema=1
strict_sif_sha256=${SIF_SHA}
strict_cactus=9.1.2
strict_samtools=samtools 9.9.9
strict_apptainer=${APP}
EOF

echo ""; echo -e "${BOLD}toolchain lock fail-closed${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"

HOMOPAN_TOOLCHAIN_LOCK="${TMP}/ok.lock" verify_toolchain_lock >/dev/null 2>&1
(( $? == 0 )) && ok "matching strict tier => PASS (audit kernel drift only warns)" || bad "matching lock should pass"

HOMOPAN_TOOLCHAIN_LOCK="${TMP}/bad.lock" verify_toolchain_lock >/dev/null 2>&1
(( $? == 1 )) && ok "strict drift (samtools) => FAIL-CLOSED (rc=1)" || bad "strict drift should fail-closed"

HOMOPAN_TOOLCHAIN_LOCK="${TMP}/bad.lock" HOMOPAN_IGNORE_TOOLCHAIN_LOCK=1 verify_toolchain_lock >/dev/null 2>&1
(( $? == 0 )) && ok "override (HOMOPAN_IGNORE_TOOLCHAIN_LOCK=1) => PASS" || bad "override should pass"

HOMOPAN_TOOLCHAIN_LOCK="${TMP}/does_not_exist.lock" verify_toolchain_lock >/dev/null 2>&1
(( $? == 0 )) && ok "missing lock => skip (rc=0, warns)" || bad "missing lock should skip, not fail"

rm -rf "${TMP}" "${SRC_ROOT}/runs/${HOMOPAN_RUN_NS}" 2>/dev/null
echo ""
echo -e "${BOLD}  Results: ${PASS} passed, ${FAIL} failed${NC}"
(( FAIL == 0 )) || { echo -e "${RED}${BOLD}TESTS FAILED${NC}"; exit 1; }
echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"; exit 0
