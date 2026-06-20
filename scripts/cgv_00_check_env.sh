#!/usr/bin/env bash
# cgv_00_check_env.sh -- Verify the CGV sub-harness toolchain & inputs.
# Fail-closed: reports exactly which tool / host / file is missing.
source "$(dirname "${BASH_SOURCE[0]}")/cgv_config.sh"

cgv_banner "CGV step 00 -- environment check"
ERR=0
ok()  { log_ok  "$*"; }
bad() { log_error "$*"; ERR=$((ERR+1)); }

# ── Aligners (in the dedicated env) ────────────────────────────────────────
log_step "Aligners (env ${CGV_ENV} @ ${CGV_ENV_BIN:-<not found>})"
[[ -n "${CGV_ENV_BIN:-}" && -d "${CGV_ENV_BIN}" ]] || bad "conda env '${CGV_ENV}' bin dir not found (create it: mamba create -n ${CGV_ENV} -c conda-forge -c bioconda minimap2 lastz mashmap ncbi-datasets-cli)"
for t in minimap2 lastz mashmap datasets; do
  if cgv_have "$t"; then ok "$t: $("$t" --version 2>&1 | head -1)"; else bad "$t not found on PATH"; fi
done

# ── Host tools (shared with the Cactus harness) ───────────────────────────
log_step "Host tools"
for t in samtools bedtools python3; do
  if cgv_have "$t"; then ok "$t: $("$t" --version 2>&1 | head -1)"; else bad "$t not found"; fi
done

# ── Python plotting stack ──────────────────────────────────────────────────
log_step "Python libraries"
if python3 -c 'import matplotlib, pandas, numpy' 2>/dev/null; then
  ok "matplotlib/pandas/numpy importable ($(python3 -c 'import matplotlib,pandas; print("mpl",matplotlib.__version__,"pandas",pandas.__version__)'))"
else
  bad "python3 cannot import matplotlib/pandas/numpy (needed by cgv_30_plot.sh)"
fi

# ── Ground truth GFF ───────────────────────────────────────────────────────
log_step "Ground truth"
if [[ -s "${TRUTH_GFF}" ]]; then
  n=$(grep -vc '^#' "${TRUTH_GFF}" 2>/dev/null || echo 0)
  ok "official NCBI GFF present: $(basename "${TRUTH_GFF}") (${n} records)"
else
  bad "official NCBI GFF missing: ${TRUTH_GFF}"
fi

# ── Egress allowlist covers NCBI (for the download step) ──────────────────
log_step "Egress allowlist (NCBI for downloads)"
ALLOW="${PROJECT_ROOT}/egress_allowlist.txt"
if [[ -f "${ALLOW}" ]] && grep -qE '(^|[^a-z])ncbi\.nlm\.nih\.gov|(^|[^a-z])nih\.gov' "${ALLOW}"; then
  ok "egress_allowlist.txt includes NCBI hosts"
else
  log_warn "egress_allowlist.txt does not list NCBI; the net-wrapper path would block it (datasets uses its own HTTP and is not wrapped, but keep the allowlist honest)."
fi

# ── Disk ───────────────────────────────────────────────────────────────────
log_step "Disk"
avail=$(df -BG "${PROJECT_ROOT}" | awk 'NR==2{print $4}' | tr -d 'G')
log_info "Primary free: ${avail} GB ($([[ "${CGV_MODE}" == full ]] && echo 'full mode downloads ~6 GB + alignment outputs' || echo 'test mode is light'))"

echo "" >&2
if (( ERR > 0 )); then
  die "Environment check FAILED with ${ERR} error(s). Fix the items above before running the pipeline."
fi
log_ok "Environment check passed. Ready for mode=${CGV_MODE}."
