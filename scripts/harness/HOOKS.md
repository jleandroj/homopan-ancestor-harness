# Auto-verification on every turn (Stop hook)

To run the honesty checks **automatically after every agent turn** (no manual
step), install a `Stop` hook that runs `scripts/harness/auto_verify.sh`.

`.claude/settings.json` is a **protected** file (the agent cannot edit it), so
**you** install it, then regenerate the gate pass:

```bash
bash patches/add_autoverify_hook.sh    # idempotent; uses jq to set the Stop hook
bash init.sh                           # regenerate the gate pass (surface changed)
```

Or add this block under `"hooks"` in `.claude/settings.json` by hand:

```json
"Stop": [
  { "matcher": "*",
    "hooks": [ { "type": "command", "command": "bash scripts/harness/auto_verify.sh" } ] }
]
```

## What runs each turn (fail-open, never blocks)
- **Cherry-pick smell** — `ledger_audit.sh` flags inputs analysed by multiple runs.
- **Declared claims** — if `claims.tsv` exists, `FactGuardAgent` checks every claim
  is backed *and* (with a token) that the cited file actually contains the value.
- **Audit-log integrity** — verifies the latest supervised run's tamper-evident chain.

It prints `🔎 AUTO-VERIFY (harness): ...` with any issues. It **cannot** read the
prose I type in chat (that is irreducible); to check a number I stated, run:

```bash
scripts/verify_agents/reconcile.sh <result_file> <stated_value> [grep_pattern]
```

## Honest limits (it still cannot catch)
- Wrong-but-valid config (flipped contrast, wrong FDR) — needs human design review.
- Why I chose a config (AI rationale) — recorded only as available, not replayable.
