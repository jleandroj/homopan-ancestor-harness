# CGV Replication Sub-Harness

Independently re-derive NCBI's **Comparative Genome Viewer (CGV)** assembly-vs-
assembly alignment between **Homo sapiens** (T2T-CHM13v2.0, `GCF_009914755.1`)
and **Pan paniscus** (bonobo mPanPan1.1, `GCF_029289425.2`) from raw DNA, with
three aligners, and **benchmark each against NCBI's official ASMASM GFF** as
ground truth. Reproduces the CGV "forward + reverse alignments" synteny figure.

This is a self-contained sub-pipeline inside the HomoPan harness. It does **not**
touch the Cactus/ancestor pipeline or any contract file. Run `bash init.sh`
first (the gate applies repo-wide).

## Ground truth

`GCF_029289425.2-GCF_009914755.1.gff` (NCBI ASMASM v3.2): **15,734** alignment
blocks — **7,338 forward (+) / 8,396 reverse (−)**; GFF `seqid` = human
(`NC_060925.1`..`NC_060948.1`), `Target` = bonobo (`NC_073*`/`NC_085*`). The
relative orientation combines the feature strand (col 7, on human) with the
Target strand (on bonobo) — same sign = forward, opposite = reverse; verified at
the sequence level against minimap2.

## Aligners benchmarked

| aligner | preset | nature |
| --- | --- | --- |
| **minimap2** | `-cx asm20 --cs` | base-level, gap-compressed identity (de:f) |
| **LASTZ** | `--gapped --chain --step=20` | UCSC/NCBI chain lineage; the slow one |
| **MashMap** | `-s 5000 --pi 90` | alignment-free, approximate identity, no CIGAR |

## Run

```bash
bash init.sh                              # repo gate (always first)
bash scripts/cgv_00_check_env.sh          # verify toolchain (env cgv_align)
bash scripts/run_all_cgv_test.sh          # ONE chromosome pair, ~minutes
bash scripts/run_all_cgv_full.sh          # whole genome, hours (+~3 GB download)
```

Toolchain lives in a dedicated conda env (isolated from the host):
`mamba create -n cgv_align -c conda-forge -c bioconda minimap2 lastz mashmap ncbi-datasets-cli`

## Pipeline steps (`scripts/cgv_*`)

| step | does |
| --- | --- |
| `cgv_config.sh` | shared lib: paths, accessions, env, logging, idempotency markers |
| `cgv_00_check_env.sh` | verify aligners / host tools / matplotlib / GFF / egress |
| `cgv_01_normalize_truth.sh` | GFF → `cgv_truth/truth_blocks.tsv` (normalized) |
| `cgv_02_select_region.sh` | pick test chr pair (most-blocks human + dominant bonobo homolog) |
| `cgv_03_fetch_genomes.sh` | download human (fresh GCF); reuse local bonobo GCF; extract pair |
| `cgv_10/11/12_align_*.sh` | minimap2 / LASTZ / MashMap → normalized `blocks.tsv` |
| `cgv_20_collect.sh` | combine blocks + per-source summary |
| `cgv_21_benchmark.sh` | recall / precision / jaccard / strand / identity vs truth (bedtools) |
| `cgv_30_plot.sh` | CGV-style synteny figure (forward = blue, reverse = red) |
| `cgv_40_report.sh` | markdown report + provenance manifest |
| `run_all_cgv{,_test,_full}.sh` | orchestrators |

## Normalized blocks schema (all aligners + truth)

```
aligner  human_chr  h_start  h_end  bonobo_chr  b_start  b_end  strand  identity_pct
```
0-based half-open on both axes; human = X, bonobo = Y.

## Outputs (`results/cgv/<mode>/`)

- `blocks/<aligner>.blocks.tsv` (+ raw PAF / general)
- `all_blocks.tsv`, `block_summary.tsv`
- `benchmark.tsv` — the headline comparison
- `figures/cgv_synteny_<mode>.png`
- `report.md`, `manifest.json`

## Key knobs

| env | default | effect |
| --- | --- | --- |
| `CGV_MODE` | `test` | `test` (one chr pair) or `full` (whole genome) |
| `CGV_FORCE_DOWNLOAD` | `0` | re-download bonobo too (default reuses local exact GCF) |
| `CGV_FORCE_ALIGN` | `0` | re-run an aligner even if its raw output is current |
| `CGV_LASTZ_TIMEOUT` | `7200` | LASTZ wall-clock cap (s) |
| `CGV_LASTZ_STEP` | `20` | LASTZ seed step (higher = faster, less sensitive) |
| `CGV_FULL_LASTZ` | `0` | include LASTZ in full mode (slow; off by default) |
| `CGV_MASHMAP_SEG` / `CGV_MASHMAP_PI` | `5000` / `90` | MashMap segment length / min identity |
| `CGV_SANDBOX` | `0` | run aligners through `scripts/sandbox_run.sh` (bubblewrap, no net) |

## Caveats

- The three aligners **approximate** NCBI's in-house ASMASM engine; the benchmark
  measures *agreement*, not correctness of CGV.
- **MashMap identity is approximate** (k-mer estimate, no base CIGAR).
- **Test mode is technical-only** — a single chromosome pair to validate the
  pipeline, not a genome-wide result.
- Re-derived alignments are not bit-reproducible across aligner versions; the
  manifest pins versions + input checksums for provenance.
