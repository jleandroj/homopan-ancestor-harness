#!/usr/bin/env bash
# run_all_cgv_test.sh -- CGV replication on ONE chromosome pair (fast, ~minutes).
# Validates the whole pipeline + figure + benchmark before committing to full.
export CGV_MODE=test
exec bash "$(dirname "${BASH_SOURCE[0]}")/run_all_cgv.sh"
