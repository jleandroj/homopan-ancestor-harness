# CLAUDE.md -- HomoPan Ancestor Reconstruction

> Auto-loaded contract pointer. Read `agents.md` for the full collaboration contract.

## Non-negotiables

1. **Run `bash init.sh` before any change.** The PreToolUse hook (`.claude/gate_check.sh`) BLOCKS Write/Edit/NotebookEdit/Bash unless init.sh has generated a valid gate pass. The gate is content-based (SHA256 of CLAUDE.md + agents.md).

2. **Stop at first error.** If init.sh fails or any pipeline step fails, stop and report verbatim. Do not attempt to fix and retry without user approval.

3. **All output in English.** Reports, comments, documentation.

4. **Never assume pipeline mode.** Ask: test or full? Which ancestors? Which regions?

5. **Never modify contract files** (CLAUDE.md, agents.md, init.sh, gate_check.sh) without explicit user approval.

6. **No external uploads.** Data stays local.

7. **Always report biological caveats** when presenting results. Ancestral genomes are inferred, not observed. Test alignments (1 Mb) are technical-only.

## Authoritative docs

- `agents.md` -- collaboration contract, safety protocol, architecture, agent roster.
- `results/reports/HomoPan_ancestor_report.md` -- pipeline output report.

## Specialized agents

Task-specific agents in `.claude/agents/`. See `agents.md` §8 for delegation rules.

## Quick reference

```bash
bash init.sh                          # Pre-flight gate (ALWAYS first)
bash scripts/run_all_test.sh          # Test pipeline (5x 1Mb, ~15 min)
bash scripts/run_all_full.sh          # Full pipeline (5x ~3GB, hours)
bash scripts/10_qc_summary.sh        # Pipeline status
HOMOPAN_WORKDIR=/mnt/s1/homopan_work bash scripts/run_all_full.sh  # Overflow disk
```
