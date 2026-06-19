# Reproducibility

This harness draws a hard line between **deterministic & verifiable** (the
Cactus/HAL compute) and **only auditable** (the LLM layer that drives Claude
Code). We never claim more than we can prove with an identical sha256 or an
empty diff.

## TL;DR — what is guaranteed

| Layer | Guarantee | How it's proven |
|------|-----------|-----------------|
| Toolchain | Pinned + fail-closed on drift | `repro/toolchain.lock` + `verify_toolchain_lock` (step 00) |
| Inputs (genomes, seqfile, tree) | Hashed per run | `repro.inputs.*` in the manifest |
| Container | Exact digest pinned | `sif_sha256` (init.sh + manifest) |
| Compute (HAL, ancestors) | **Bit-identical across runs** *(see caveat)* | `scripts/repro_verify.sh`, `tests/test_repro_verify.sh` |
| Run provenance | Immutable, comparable | per-run manifest + `compare_runs.sh` |
| **LLM reasoning** | **NOT reproducible** — only recorded | `meta.llm.*` (session/agent/effort/model_id) |

## Deterministic & verifiable (the compute)

Given the **same manifest inputs + same SIF + same `CACTUS_SEED`**, the test
path (1 Mb) is designed to produce **bit-identical** artifacts. We prove this two
ways:

- **CI (always):** `tests/test_repro_verify.sh` runs the test pipeline **twice**
  on synthetic genomes with a **deterministic mock** toolchain and asserts the
  two HALs + ancestor FASTAs have an **identical sha256**, and that the two
  manifests share an identical `repro_sha256`. This proves the *harness* injects
  no non-determinism (no clock/randomness in artifacts) and feeds identical
  inputs to both runs.
- **Real toolchain (on demand):** `bash scripts/repro_verify.sh` runs the real
  test pipeline twice (two namespaces, same seed) and **measures** bit-identity.
  If real Cactus is bit-deterministic → PASS. If it is not (Toil parallelism /
  abPOA can be non-deterministic), the script reports the diverging artifact and
  falls back to a **documented equivalence metric** (ancestral-sequence identity
  ≥ `HOMOPAN_REPRO_IDENTITY`, default 0.999). We do **not** pre-claim real-Cactus
  bit-identity — the verifier states the honest verdict.

### Commands

```bash
# Prove harness determinism (fast, synthetic, deterministic mock) — also in verify.sh:
bash tests/test_repro_verify.sh

# Measure REAL determinism of the test path (runs Cactus twice; minutes):
bash scripts/repro_verify.sh                  # bit-identical => PASS

# Replay a past run from its manifest into a fresh namespace, then confirm:
bash scripts/replay_run.sh <run_id>           # re-runs with the recorded seed/inputs
bash scripts/replay_run.sh --list             # list available run_ids

# Compare two runs rigorously (verdict from the canonical repro block):
bash scripts/compare_runs.sh <run_id_a> <run_id_b>

# (Re)generate the toolchain lock from the live host:
bash scripts/repro_verify.sh --write-lock
```

## Only auditable (the LLM layer)

Claude Code's model is **non-deterministic** and its weights/seed are **not
controllable from this repo**. We therefore make **no claim** of reproducing the
agent's reasoning. We only **record**, in each manifest's `meta.llm`:

- `session_id` (`CLAUDE_CODE_SESSION_ID`), `agent` (`AI_AGENT`), `effort`
  (`CLAUDE_EFFORT`);
- `model_id` — **`unexposed`** unless you set `HOMOPAN_MODEL_ID` explicitly,
  because the exact model id is **not** exposed to the shell environment.

This is provenance for *audit*, never a promise of *replay*.

## Fail-closed controls (drift → stop, with explicit override)

- **Toolchain drift:** `00_check_env.sh` calls `verify_toolchain_lock`. A change
  in an **output-determining** tool (SIF digest, in-container cactus, samtools,
  apptainer — the `strict_*` tier of `repro/toolchain.lock`) **fails the run**.
  Non-determining tools (`audit_*`: bedtools/jq/bash/kernel) only **warn**.
  Override a justified bump with `HOMOPAN_IGNORE_TOOLCHAIN_LOCK=1`.
- **Input drift:** `replay_run.sh` re-verifies each genome sha256 against the
  manifest and **aborts** on mismatch (`HOMOPAN_REPLAY_SKIP_INPUT_CHECK=1` to
  override).
- **Seeding:** `CACTUS_SEED` (default 0) is passed to Cactus when the container
  supports `--seed` (probed once); the manifest records whether it was effective
  (`repro.cactus_seed_active`).

## Honest caveats

- **The 1 Mb test path is technical only** — a determinism check, **not** a
  biological result.
- **Ancestral genomes are inferred**, not observed.
- **Bit-identity is guaranteed only where proven** (the mock/CI path). For real
  Cactus it is measured-and-reported; if the upstream tool is non-deterministic,
  equivalence is documented and justified rather than overclaimed.
- The kernel/bash/jq/bedtools versions are recorded but treated as
  **non-determining** for a containerized Cactus run; only the strict tier blocks.
