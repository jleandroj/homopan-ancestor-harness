# Run manifest schema (v2)

One immutable JSON per run at `<state>/qc/manifests/<run_id>.json`, written by
`write_run_manifest()` (`scripts/config.sh`) at the end of every run (step 10,
which runs in both the test and full orchestrators). `<state>` is the project
root, or `runs/<HOMOPAN_RUN_NS>/` when a namespace is set.

The manifest is split so that **what determines the bytes** is separated from
**what is only metadata**:

```json
{
  "schema": 2,
  "repro": {                      // DETERMINISTIC + VERIFIABLE. Sorted keys.
    "cactus": "9.1.2",            //   in-container cactus version (clean triple)
    "cactus_seed": "0",          //   configured seed
    "cactus_seed_active": false, //   whether --seed was actually passed (probe)
    "samtools": "samtools 1.21", //   host samtools (extracts test FASTAs)
    "sif_sha256": "0124bac3…",   //   exact container digest
    "toolchain_lock_sha256": "…",//   sha256 of repro/toolchain.lock in force
    "newick": "(((homo_sapiens…",//   the tree topology + branch lengths
    "test_region_len": "1000000",
    "inputs": {
      "genomes": { "homo_sapiens": {"sha256":"…","bytes":"…"}, … },
      "seqfile_test_sha256": "…",
      "seqfile_full_sha256": "…"
    },
    "outputs": {
      "test_hal_sha256": "…",
      "full_hal_sha256": "…",
      "ancestors": { "Anc_HomoPan": {"sha256":"…","bp":"…","n_fraction":"…"}, … }
    }
  },
  "repro_sha256": "…",            // sha256 of the canonical (jq -S -c) repro{} block
  "meta": {                       // AUDITABLE-ONLY. NOT in repro_sha256.
    "run_id": "20260619_…_123",
    "timestamp": "2026-06-19T13:…",
    "namespace": "agentA",
    "host": "…",
    "apptainer": "apptainer version 1.4.5",
    "llm": {                      // LLM provenance: recorded, NEVER promised reproducible
      "session_id": "…",          //   from CLAUDE_CODE_SESSION_ID
      "agent": "…",               //   from AI_AGENT
      "effort": "…",              //   from CLAUDE_EFFORT
      "model_id": "unexposed",    //   exact model id is NOT exposed to the shell;
      "note": "LLM reasoning is non-deterministic and not repo-controllable; auditable only."
    }
  }
}
```

## Key invariants

- **`repro_sha256` is a pure function of `repro{}`** — independent of `run_id`,
  `timestamp`, `host`, and the LLM layer. Two equivalent runs share an identical
  `repro_sha256` and differ **only** in `meta{}`. `scripts/compare_runs.sh` uses
  this as its verdict.
- **Immutable**: keyed by `run_id`, never overwritten; a later run cannot clobber
  an earlier manifest. (Tested in `tests/test_manifest.sh`.)
- **Sorted keys** (`jq -S`) so the canonical form — and therefore the hash — is
  stable across runs and machines.
- **No timestamps inside the hashed block** (they live in `meta{}`).

## What is determined vs only recorded

| Field | Determines output? | Notes |
|------|--------------------|-------|
| `repro.sif_sha256`, `repro.cactus`, `repro.samtools` | YES | toolchain (strict tier of the lock) |
| `repro.inputs.*`, `repro.newick`, `repro.cactus_seed*` | YES | data + parameters |
| `repro.outputs.*` | result | the artifacts' own hashes |
| `meta.*` (timestamp, host, run_id) | NO | provenance |
| `meta.llm.*` | NO | LLM layer is non-deterministic; auditable only |

Caveat: the 1 Mb test path is a **technical** determinism artifact, not biology;
ancestral sequences are **inferred**, not observed.
