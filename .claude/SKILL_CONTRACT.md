# Skill Contract (#11)

Every skill under `.claude/skills/<name>/` is a unit of delegated capability.
To stay auditable and least-privilege, each must honor this contract. The
validator `tests/test_skill_contracts.sh` enforces the **MUST** items and warns
on the **SHOULD** items.

## MUST (enforced — test fails otherwise)

1. **`SKILL.md` exists** at `.claude/skills/<name>/SKILL.md`.
2. **`name:`** frontmatter field is present and **equals the directory name**
   (so the skill the loader resolves is the one on disk).
3. **`description:`** frontmatter field is present and non-empty (this is the
   routing signal; an empty description makes the skill unselectable/ambiguous).
4. **`allowed-tools:`** frontmatter field is present and non-empty. This is the
   skill's **minimum permission set** — the tools it is allowed to invoke.
5. **`allowed-tools` is a subset of the project-permitted tool set**
   (`Read, Grep, Glob, Bash, Write, Edit, NotebookEdit, Task, TodoWrite`).
   A skill may not silently grant itself a tool the harness doesn't sanction.
6. **No egress tools** (`WebFetch`, `WebSearch`) in `allowed-tools` — the
   project is no-egress by policy (see SECURITY.md). Network, if ever needed,
   goes through `scripts/sandbox_run.sh` + the egress allowlist, not a skill.

## SHOULD (warned — not fatal)

- Declare an **`Inputs`** section (what files/args the skill consumes).
- Declare an **`Outputs`** section (what artifacts it produces, and where).
- Declare **`Success criteria`** (how a caller knows the skill succeeded —
  e.g. "a valid HAL that passes `halValidate`", not just "it ran").
- Keep `allowed-tools` minimal: request `Write`/`Edit` only if the skill
  actually mutates files; prefer `Read`/`Grep`/`Glob` for analysis-only skills.

## Rationale

The skill frontmatter is the only machine-readable description of what a skill
can touch. Treating `allowed-tools` as a real permission floor (MUST #4–6) keeps
a skill from quietly expanding its blast radius, and the I/O + success-criteria
sections (SHOULD) make a skill's effects predictable to the orchestrator that
delegates to it. The gate folds the whole `skills/` tree into its hash, so any
change to a skill (including its declared tools) invalidates the gate pass until
`bash init.sh` re-runs — this contract makes that change reviewable.

## Not a runtime boundary (honest scope — P3.3)

`allowed-tools` is **declarative and reviewed**, not **runtime-enforced**: the
skill loader does not sandbox a skill to its declared tools. A skill cannot
exceed what the agent itself can do, and the **actual** enforcement boundaries
are, in order of strength:

1. `scripts/sandbox_run.sh` (bubblewrap, no-egress) — the only real containment.
2. The PreToolUse gate (`.claude/gate_check.sh`) + `permissions.deny` —
   defense-in-depth, heuristic (see `SECURITY.md`).

The `bio-*` skills here are **reference/documentation** — curated workflows,
tool-selection guidance, and example scripts — **not** privileged code paths.
`allowed-tools` + the contract test (`tests/test_skill_contracts.sh`) make a
skill's intended surface auditable and reviewable; they do **not** confine it at
run time. Do not rely on `allowed-tools` as a security control; rely on the gate
and the sandbox.
