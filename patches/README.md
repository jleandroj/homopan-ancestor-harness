# Contract-file patches (require manual application)

These patch **protected security-surface files** that the gate (`gate_check.sh`)
hardline-denies the agent from editing. Apply them yourself, then re-run the
gate to regenerate the pass.

## P0-a — Close the Bash write-bypass and `.gate_pass` forge

**File:** `.claude/gate_check.sh`
**Proposed full file:** `patches/gate_check.sh`
**Diff for review:** `patches/gate_check.sh.diff`

### What it fixes
The live gate only hardline-denies `Write`/`Edit`/`NotebookEdit` on protected
files. A `Bash` command such as `echo x >> CLAUDE.md` or
`echo <hash> > .claude/.gate_pass` was **allowed** (demonstrated: exit 0).
The patch adds `bash_writes_protected()`, which denies Bash commands that
redirect/`tee`/`cp`/`mv`/`sed -i`/interpreter-write into any protected file,
and denies **any** Bash reference to `.gate_pass`. The gate-pass hash remains
the backstop for obfuscated writes (any real change invalidates the pass).

### Apply
```bash
cp patches/gate_check.sh .claude/gate_check.sh   # review patches/gate_check.sh.diff first
bash init.sh                                      # regenerates the gate pass over the new surface
```

### Verify
```bash
bash tests/test_gate_sandbox.sh    # expect: 35 passed, 0 failed
bash tests/test_gate.sh            # expect: 48 passed, 0 failed
```
Before applying, `tests/test_gate_sandbox.sh` shows **7 failures** in section 8
(the bypass cases) — that is the regression test proving the bug exists.
