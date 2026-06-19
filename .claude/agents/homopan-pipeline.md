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
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
bash scripts/run_all_test.sh
```

### Full Mode (user must explicitly request)
```bash
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
bash scripts/run_all_full.sh
```

### Full Mode with alternate disk
```bash
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
HOMOPAN_WORKDIR=/mnt/s1/homopan_work bash scripts/run_all_full.sh
```

## Pre-conditions

- init.sh must pass
- All genomes must exist and be indexed
- Container must be accessible
- For full mode: user must confirm sufficient disk space

## Idempotency

Steps already completed (`<state>/targets/*.done`) are skipped automatically,
where `<state>` is the project root by default, or `runs/$HOMOPAN_RUN_NS/` when a
namespace is set (see Multi-agent below).
To force re-run a step: `rm <state>/targets/STEP_NAME.done`
To re-run everything: `rm <state>/targets/*.done`

## Multi-agent isolation (HOMOPAN_RUN_NS)

When several agents share this repo, each MUST set a distinct `HOMOPAN_RUN_NS`
so their state (targets/results/work/logs/seqfiles) is isolated under
`runs/<NS>/` and they don't collide. `genomes/` stays shared read-only. Example:
```bash
HOMOPAN_RUN_NS="$AGENT_NAME" bash scripts/run_all_test.sh
```
Without `HOMOPAN_RUN_NS`, state stays at the project root (legacy single-agent
layout). Two agents with NO namespace serialize on one shared `pipeline.lock`.

## Attribution in the audit log

The PostToolUse logger (`logs/bitacora.jsonl` + external audit log) tags every
mutating tool call with `session` and `cwd`, taken from the hook payload — so
each Claude Code session is automatically distinguishable (each agent = its own
`session_id`). No setup needed for `session`/`cwd`.

For human-readable labels, launch the agent with env vars (Claude Code passes
its environment to hooks):
```bash
HOMOPAN_AGENT=alignment-bot HOMOPAN_RUN_NS=alignment-bot claude ...
```
Then log lines carry `"agent":"alignment-bot"` too. `agent`/`run_id` show
`"unknown"` only when those vars are unset; `session`/`cwd` populate regardless.

## Error Handling

If any step fails:
1. Report the exact error output
2. Do NOT attempt to fix and retry automatically
3. Ask the user how to proceed
