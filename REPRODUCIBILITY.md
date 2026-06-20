# Reproducibility

This harness draws a hard line between what is **proven** and what is **only
auditable**. We never claim more than we can prove with an identical sha256 or an
empty diff.

> **MEASURED FINDING (2026-06):** the compute layer (Progressive Cactus) is
> **NOT bit-reproducible** on this toolchain. The container's Cactus **9.1.2 has
> no RNG `--seed`** and `cactus_consolidated` runs multi-threaded; two real runs
> of the **same inputs and seed** produced **different** HAL + ancestral genomes.
> Forcing single-thread (`--consCores 1 --lastzCores 1 --maxCores 1`) **also
> diverged**. Ancestral genomes are therefore treated as **non-deterministic
> inferences**; see *Policy* below. Earlier wording that promised "bit-identical"
> compute was aspirational and has been corrected.

## TL;DR — what is guaranteed

| Layer | Guarantee | How it's proven |
|------|-----------|-----------------|
| Toolchain | Pinned + fail-closed on drift | `repro/toolchain.lock` + `verify_toolchain_lock` (step 00) |
| Inputs (genomes, seqfile, tree) | Hashed per run | `repro.inputs.*` in the manifest |
| Container | Exact digest pinned | `sif_sha256` (init.sh + manifest) |
| Sandboxing of compute | Recorded per run | `meta.sandboxed` (true/false/unknown) |
| **Harness** determinism | **No clock/randomness injected** | mock CI: `tests/test_repro_verify.sh` (bit-identical under a deterministic stub) |
| **Compute (HAL, ancestors)** | **NOT bit-reproducible (measured)** — inference + provenance + equivalence | `scripts/repro_verify.sh` real verdict; `scripts/annotate_ancestral_provenance.sh` |
| Run provenance | Immutable, comparable | per-run manifest + `compare_runs.sh` |
| **LLM reasoning** | **NOT reproducible** — only recorded | `meta.llm.*` (session/agent/effort/model_id) |

## What IS proven: the harness injects no non-determinism

`tests/test_repro_verify.sh` (CI) runs the test pipeline **twice** on synthetic
genomes with a **deterministic mock** toolchain and asserts the two HALs +
ancestor FASTAs share an **identical sha256** and the manifests share an
identical `repro_sha256`. This proves the *harness* (paths, ordering, manifest)
adds no clock/randomness and feeds identical inputs to both runs. It says
**nothing** about real Cactus — only the stub.

## What is NOT proven: real Cactus is non-deterministic (measured)

`bash scripts/repro_verify.sh` runs the **real** test pipeline twice and compares.
Measured verdict on Cactus 9.1.2:

- HAL and ancestral FASTA **diverge** byte-for-byte across runs (same seed=0).
- Root cause (verified by probing the container):
  - `cactus --help` exposes **no RNG `--seed`** (only `--badWorker`); so
    `CACTUS_SEED` is a **no-op** and `repro.cactus_seed_active` is always `false`.
  - `cactus_consolidated` runs `--threads=all` by default (thread non-determinism).
  - Forcing single-thread via `CACTUS_EXTRA_ARGS="--consCores 1 --lastzCores 1
    --maxCores 1"` **still diverged** → non-determinism is deeper than threads
    (Toil job ordering, temp paths, unseeded abPOA/lastz internals).
- When artifacts diverge, the verifier reports an **alignment-based equivalence
  metric** (container `minimap2`: gap-compressed identity **and** aligned
  coverage; "equivalent" requires **both** ≥ `HOMOPAN_REPRO_IDENTITY`, default
  0.999). This replaces an earlier naive positional metric that was meaningless
  for sequences of differing length/coordinates.

## Policy (Option C): inference + provenance + (optional) consensus

Because the compute is non-deterministic and this is not fixable in-tool, every
ancestral genome is treated as an **inference**, not a canonical sequence:

1. **Annotate every produced genome.** Run
   `bash scripts/annotate_ancestral_provenance.sh [ancestors_dir] [run_id]`.
   It writes a `<genome>.provenance.json` sidecar + `PROVENANCE.md` +
   `NON_DETERMINISTIC_WARNING.txt` recording name, date, sha256, bp, git commit,
   Cactus version, SIF digest, **how it was generated**, and an explicit
   `determinism:{reproducible:false}` block. The FASTA is left pristine.
2. **For a citable / reproducible ancestor**, reconstruct the ancestral sequence
   with a **deterministic** tool over a **fixed** alignment — e.g. IQ-TREE
   `--ancestral -seed N -nt 1`, or PHAST `phyloFit`+`prequel`, or PAML `baseml`
   (all deterministic given fixed inputs + single thread). This trades Cactus's
   reference-free WGA for reproducibility.
3. **To quantify variance**, run N times and compare with the alignment metric
   (identity + coverage) to report run-to-run spread, or build a consensus with
   per-position confidence. Never present a single run's bytes as definitive.

## Only auditable: the LLM layer

Claude Code's model is **non-deterministic** and its weights/seed are **not
controllable from this repo**. We make **no claim** of reproducing the agent's
reasoning; we only **record** in each manifest's `meta.llm`: `session_id`,
`agent`, `effort`, and `model_id` (**`unexposed`** unless `HOMOPAN_MODEL_ID` is
set, since the exact id is not in the shell env). Provenance for *audit*, never a
promise of *replay*.

## Fail-closed controls (drift → stop, with explicit override)

- **Toolchain drift:** `00_check_env.sh` → `verify_toolchain_lock`. A change in an
  output-determining tool (`strict_*`: SIF digest, in-container cactus, samtools,
  apptainer) **fails the run**; non-determining tools (`audit_*`) only **warn**.
  Override with `HOMOPAN_IGNORE_TOOLCHAIN_LOCK=1`.
- **Input drift:** `replay_run.sh` re-verifies each genome sha256 and **aborts**
  on mismatch (`HOMOPAN_REPLAY_SKIP_INPUT_CHECK=1` to override).
- **Compute sandbox:** fail-closed — if a sandbox is requested but the host lacks
  unprivileged userns, the run **aborts** unless you opt out explicitly
  (`HOMOPAN_SANDBOX_COMPUTE=0` or `HOMOPAN_ALLOW_UNSANDBOXED=1`), which is stamped
  `sandboxed:false` in the manifest.

## Commands

```bash
bash tests/test_repro_verify.sh        # harness determinism (mock, fast, CI)
bash scripts/repro_verify.sh           # MEASURE real determinism (honest verdict)
bash scripts/annotate_ancestral_provenance.sh   # stamp genomes as non-deterministic inferences
bash scripts/compare_runs.sh A B       # rigorous diff via the canonical repro block
bash scripts/replay_run.sh <run_id>    # re-run from a manifest (inputs re-verified)
bash scripts/repro_verify.sh --write-lock        # regenerate the toolchain lock
```

## Honest caveats

- The 1 Mb test path is **technical only**, not a biological result.
- **Ancestral genomes are inferred and non-deterministic** — annotate them.
- Real-Cactus bit-identity is **disproven** here; only the mock/CI harness path is
  bit-identical. Equivalence is measured (alignment-based) and reported, never
  overclaimed.
