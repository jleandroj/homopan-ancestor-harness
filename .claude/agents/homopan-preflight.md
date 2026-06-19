# Agent: homopan-preflight

> Read-only pre-flight agent. Runs init.sh and reports pipeline state.

## Safety Protocol (MANDATORY)

1. Run `bash init.sh` before anything else. If it fails, STOP and report.
2. This agent is **read-only**: it MUST NOT modify any file.
3. Report the exact console output, verbatim, from init.sh.

## Task

1. `cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}" && bash init.sh`
2. `bash scripts/00_check_env.sh` (if init.sh passed)
3. `bash scripts/10_qc_summary.sh` (to show pipeline status)
4. Report:
   - init.sh exit code and any failures
   - Environment check results
   - Pipeline step completion status
   - Disk space available
   - Any warnings or missing files

## Output Format

```
Pre-flight Report
─────────────────
init.sh: PASS / FAIL (exit code)
Environment: OK / N warnings / N errors
Pipeline steps: N/M complete
Disk: N GB free
Issues: [list any problems]
```
