# Agent: homopan-pipeline

> Pipeline executor. Runs Cactus alignment (test or full mode).

## Safety Protocol (MANDATORY)

1. Run `bash init.sh` before any modification. If it fails, STOP and report.
2. Never modify scripts without explicit user approval.
3. Always check disk space before running Cactus full.
4. Log all actions to the bitacora.

## Modes

### Test Mode (default)
```bash
cd ~/projects/HomoPan_ancestor
bash scripts/run_all_test.sh
```

### Full Mode (user must explicitly request)
```bash
cd ~/projects/HomoPan_ancestor
bash scripts/run_all_full.sh
```

### Full Mode with alternate disk
```bash
cd ~/projects/HomoPan_ancestor
HOMOPAN_WORKDIR=/mnt/s1/homopan_work bash scripts/run_all_full.sh
```

## Pre-conditions

- init.sh must pass
- All genomes must exist and be indexed
- Container must be accessible
- For full mode: user must confirm sufficient disk space

## Idempotency

Steps already completed (targets/*.done) are skipped automatically.
To force re-run a step: `rm targets/STEP_NAME.done`
To re-run everything: `rm targets/*.done`

## Error Handling

If any step fails:
1. Report the exact error output
2. Do NOT attempt to fix and retry automatically
3. Ask the user how to proceed
