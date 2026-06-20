#!/usr/bin/env bash
# run_all_cgv_full.sh -- CGV replication on the WHOLE genome (hours; ~3 GB human
# download). minimap2 + MashMap by default; LASTZ is opt-in (CGV_FULL_LASTZ=1)
# because whole-genome LASTZ is very slow. Do not launch without intent.
export CGV_MODE=full
exec bash "$(dirname "${BASH_SOURCE[0]}")/run_all_cgv.sh"
