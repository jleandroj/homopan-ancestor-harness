# 🛑 AI / AGENTS — READ THIS FIRST (before doing anything)

You are operating in a harness whose **#1 rule is: EXECUTION IS NOT TRUTH.**
A command exiting 0 is not a correct result. A figure is not a valid inference.
A derived/inferred artifact is not an observed fact. A non-reproducible result is
not evidence.

**Your obligation here is 100% operational honesty, not 100% certainty.**
When you cannot prove something, you MUST say one of:
`UNKNOWN · NOT_TESTED · NOT_REPRODUCIBLE · INSUFFICIENT_EVIDENCE · EXPLORATORY ONLY · FAILED VALIDATION`
— never invent, never overstate, never present "it ran" as "it is true".

## Before you conclude, claim, or report anything, you MUST:
1. **Read the full playbook:** `docs/ANTI_DECEPTION_PLAYBOOK.md`.
2. **Recompute, don't trust** any "it passed / it matches / it's reproducible" — hash it yourself.
3. **Back every claim with evidence** (a file/command/PMID) and, if you state a
   number, write it to `claims.tsv` (`claim ⇥ file ⇥ token`) so it is reconciled
   against the file on disk. Prose is never trusted.
4. **Never call a derived/inferred artifact "observed".** Mark it inferred, exploratory.
5. **Disclose your blind spots** in your report: wrong-but-valid config, your own
   rationale, and any undeclared prose are NOT checked — say so.
6. **Run everything through the harness** (`scripts/run_supervised.sh` /
   `scripts/harness/harness.sh run`) so it is logged, contained, and verifiable.

## Self-check before finishing
Run the verifier; it tells you, in your own report, what it could and could NOT verify:
```bash
bash scripts/verify_agents/coordinator.sh <context_dir>   # gated verdict + report
bash scripts/verify_agents/reconcile.sh <file> <number_you_stated> [pattern]
```
A biological/scientific PASS is only allowed if evidence + provenance +
reproducibility all pass. Otherwise downgrade to PASS_EXPLORATORY / UNKNOWN.

> If you follow this, you cannot lie in silence about anything verifiable.
> Where you still could fool the user (config intent, your reasoning), you MUST
> declare it. Bias toward "I don't know" over false confidence. **Now read
> `docs/ANTI_DECEPTION_PLAYBOOK.md`.**
