---
name: comparative-genomics-cactus
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
description: >-
  World-class workflow for building and analyzing reference-free, multi-genome
  whole-genome alignments with Progressive Cactus, then mining them for
  evolutionary signal. Use this skill WHENEVER the user wants to align multiple
  whole genomes, build or query a HAL alignment, run Progressive Cactus or
  cactus-pangenome, reconstruct ancestral genomes, compute conservation
  (phyloP/phastCons/GERP), call conserved or accelerated elements, detect
  introgression or lineage-specific gains/losses, prepare a Newick species tree
  for alignment, softmask repeats for genome alignment, or orchestrate any of
  these on a SLURM HPC cluster. Trigger it even when the user only mentions the
  inputs or outputs (e.g. "I have 12 genome FASTAs and a tree", "I need a HAL
  file", "halStats", "MAF for these species", "ancestral reconstruction") rather
  than naming Cactus explicitly. This is a heavy, multi-step, error-prone
  pipeline — prefer this skill over improvising.
---

# Comparative Genomics with Progressive Cactus

Build a reference-free multiple whole-genome alignment from a set of genome
assemblies and a species tree, store it as a HAL file, validate it, and extract
evolutionary signal (conservation, ancestral sequence, lineage-specific change,
introgression). This is the canonical pipeline behind comparative-genomics
resources like the Zoonomia / 200 Mammals and vertebrate genome alignments.

## Why this skill exists

Cactus runs are long (hours to days), expensive (10s–100s of CPU-hours and large
RAM/scratch), and fail in characteristic ways: an unmasked genome explodes the
runtime, a malformed Newick tree silently produces garbage, a name mismatch
between tree leaves and FASTA files aborts the run after hours, and scratch I/O
storms get jobs killed by HPC admins. The whole point of this skill is to do the
boring validation *before* burning compute, choose the right execution mode, and
never fabricate biological results when a step fails.

## Golden rules (read before doing anything)

1. **Validate inputs before submitting any long job.** A 30-second check saves a
   12-hour failed run. Always run the preflight in `scripts/preflight.py`.
2. **Never invent or "fill in" alignment results, conservation scores, or branch
   stats.** If a step fails or output is missing, stop and report what is missing.
3. **Do not modify the user's input genomes or tree in place.** Copy to a working
   directory; write all derived files under a dedicated `work/` and `results/`.
4. **Be explicit about every assumption** (genome version, masking state,
   tree rooting, outgroup) and print intermediate counts at each step.
5. **Respect the cluster.** Use the job store on fast/local scratch, never on a
   shared metadata-heavy filesystem; batch jobs; never poll squeue in tight loops.

## Workflow overview

```
0. Preflight & input QC      -> validate tree, FASTAs, names, masking
1. Repeat masking (if needed)-> softmask repeats (lowercase) in every genome
2. Build the seqFile          -> Newick tree + genome paths, one source of truth
3. Choose execution mode      -> single-machine | cactus-prepare+SLURM | GPU
4. Run Progressive Cactus     -> produces alignment.hal
5. Validate the HAL           -> halStats, halValidate, coverage sanity checks
6. Downstream analysis        -> MAF export, conservation, ancestors, introgression
7. Report                     -> what ran, where outputs are, caveats
```

Do the steps in order. Don't skip preflight. Read the referenced files only when
you reach the step that needs them, to keep context lean.

---

## Step 0 — Preflight & input QC (ALWAYS)

Run `python scripts/preflight.py --seqfile <seqFile> ` (or pass tree + a directory
of FASTAs). It checks, and you must confirm, all of the following:

- The **tree is valid Newick**: parses, is rooted, ends in `;`, branch lengths are
  non-negative, no zero/duplicate leaf names. A common silent failure is an
  unrooted or multifurcating tree — Cactus needs a rooted binary-ish tree.
- **Leaf names exactly match the genome identifiers** used in the seqFile (case,
  punctuation, no spaces). Mismatches abort the run late. No whitespace or special
  characters in names; use `[A-Za-z0-9_]`.
- **Every FASTA exists, is readable, and is softmasked.** Estimate masked fraction
  (lowercase bases). For mammalian-size genomes expect roughly >40% masked; near 0%
  means the genome is unmasked → go to Step 1 first or runtime will blow up.
- **Assembly sanity**: contig count, total length, N50, fraction of Ns. Flag
  genomes that look like raw reads, are tiny, or are >50% N.

State the results plainly to the user and get a go-ahead before any long job.
See `references/inputs_and_tree.md` for the exact validation criteria and how to
re-root or resolve a tree with standard tools.

## Step 1 — Repeat masking (only if a genome is not softmasked)

Cactus expects **softmasked** genomes (repeats in lowercase, not removed). Hard
masking (Ns) destroys signal — never hard-mask for alignment. If masking is
missing, softmask with RepeatMasker (lineage library) or, as a fast fallback,
`windowmasker`. Document exactly what was used; record masked fraction before/after.
Details and commands: `references/masking.md`.

## Step 2 — Build the seqFile (single source of truth)

The Cactus **seqFile** is one text file: first line is the Newick tree, then one
`name path` line per genome. The names MUST equal the tree leaves. Ancestral nodes
are not listed. Example:

```
((human:0.006,chimp:0.006)Anc1:0.07,(mouse:0.08,rat:0.08)Anc2:0.07)root;
human   /work/genomes/hg38.softmask.fa
chimp   /work/genomes/panTro6.softmask.fa
mouse   /work/genomes/mm39.softmask.fa
rat     /work/genomes/rn7.softmask.fa
```

Generate this file programmatically from validated inputs; never hand-edit names
after validation. Use absolute paths.

## Step 3 — Choose the execution mode

Pick deliberately and tell the user which one and why. See
`references/running_cactus.md` for full command templates of each.

- **Single machine** (small jobs, few small genomes, a fat node): run `cactus`
  directly with a local `jobStore` on fast scratch. Simplest, no scheduler.
- **`cactus-prepare` + SLURM** (the default for HPC / many or large genomes):
  `cactus-prepare` expands the seqFile into a dependency-ordered set of commands /
  a job plan that you submit as SLURM steps. This is the robust path on a cluster
  like Sherlock; it parallelizes the independent subproblems of the guide tree.
- **GPU mode** (SegAlign): large vertebrate genomes, if GPU nodes are available.
  Much faster lastz/SegAlign step; requires the GPU-enabled container.

Always run inside the **official Cactus container** (Singularity/Apptainer or
Docker) so tool versions are pinned and reproducible. Put the `jobStore` and
`--workDir` on **local/fast scratch**, never on a shared metadata filesystem, and
clean them up after — runaway job stores are the #1 cause of HPC admin complaints.

## Step 4 — Run Progressive Cactus

Submit the chosen mode. The primary output is a single **`alignment.hal`**.
Key operational guidance (full templates in `references/running_cactus.md`):

- Set `--maxCores` / SLURM resources to match the node; give lastz/SegAlign steps
  the most memory.
- Use `--restart` (single machine) or resubmit the remaining `cactus-prepare` steps
  to **resume** a partially complete run rather than starting over — Cactus is
  checkpointed through its jobStore.
- Capture the full log; the run is not "done" just because a step finished — confirm
  the final HAL was written and is non-empty.

## Step 5 — Validate the HAL (do not skip)

Before any downstream analysis, prove the alignment is real:

- `halStats alignment.hal` — genomes present (including reconstructed ancestors),
  sequence counts, and total/aligned lengths. Confirm every input leaf AND the
  expected internal ancestor nodes are present.
- `halValidate alignment.hal` — structural integrity.
- **Coverage sanity check**: `halStats --coverage <genome>` for a couple of genomes;
  pairwise coverage should be biologically plausible (close species high, distant
  lower). Coverage near zero across the board means a broken alignment — stop and
  diagnose, don't proceed.

Report the numbers. If validation fails, treat the run as failed.

## Step 6 — Downstream evolutionary analysis

Choose based on the user's actual question; read the matching reference only then.
See `references/downstream.md` for commands and gotchas for each.

- **Export alignments**: `hal2maf` (MAF, ref-based) or `hal2fasta` for a genome;
  `halLiftover` to move annotations between genomes through the alignment.
- **Conservation**: build a neutral model (phyloFit on 4-fold degenerate sites),
  then phyloP / phastCons for per-base conservation and conserved elements; GERP for
  constraint. State the reference genome and neutral model explicitly.
- **Ancestral genomes**: extract reconstructed ancestral sequence with `hal2fasta`
  on an internal node; useful for polarizing changes and lineage-specific analysis.
- **Lineage-specific gain/loss & accelerated regions**: compare conservation across
  branches; identify human/lineage accelerated regions, gains, and losses.
- **Introgression**: when the question is archaic/introgression (the user's frequent
  domain), the HAL gives a clean reference-free coordinate system to pull homologous
  regions across genomes and compare with archaic genome tracks. Combine with site-
  pattern statistics (e.g. D / ABBA-BABA, f-statistics) computed from extracted
  alignments — but be explicit that introgression inference needs an appropriate
  outgroup and that the alignment alone is not proof of introgression.

Always separate "what the alignment shows" from "what it implies biologically,"
and surface caveats: incomplete lineage sorting, masking artifacts, low-coverage
genomes, reference bias in MAF.

## Step 7 — Report

End with a concise report:
- inputs used (genomes + versions, tree, masking state) and any assumptions made,
- execution mode and resources, where the jobStore/workDir lived (and that it was
  cleaned up),
- output paths (`alignment.hal`, MAFs, conservation tracks, ancestral FASTAs),
- HAL validation numbers (genomes present, coverage sanity),
- the specific evolutionary result and its caveats,
- how to resume or extend the run.

---

## SLURM orchestration notes

- Submit with `sbatch`; request memory generously for lastz/SegAlign; check with
  `squeue -u $USER`; inspect a finished job with `sacct`/`seff` to right-size the
  next run. Don't poll `squeue` in a tight loop.
- Put `--jobStore` and `--workDir` on node-local or fast parallel scratch. Never on
  `$HOME` or a metadata-sensitive filesystem; Cactus creates huge numbers of small
  files and will trigger I/O alerts.
- Prefer fewer, larger jobs over thousands of tiny ones (the metadata-I/O lesson).
- See `references/running_cactus.md` for ready-to-edit `sbatch` templates and a
  `cactus-prepare`-driven submission pattern.

## When NOT to use this skill

- Aligning short reads to one reference (use bwa/minimap2 + samtools instead).
- Variant calling, STR genotyping, RNA-seq quantification — different pipelines.
- A single pairwise genome alignment where lastz/minimap2 alone is enough and a full
  multiple alignment is overkill.

## Reference files

- `references/inputs_and_tree.md` — input validation criteria, Newick rules,
  re-rooting/resolving a tree, name harmonization.
- `references/masking.md` — softmasking with RepeatMasker / windowmasker, QC.
- `references/running_cactus.md` — container setup, single-machine, cactus-prepare,
  GPU mode, SLURM sbatch templates, restart/resume.
- `references/downstream.md` — hal2maf, halLiftover, phyloFit/phyloP/phastCons,
  GERP, ancestral extraction, accelerated regions, introgression statistics.

## Bundled scripts

- `scripts/preflight.py` — validates the seqFile/tree/FASTAs and reports masking and
  assembly stats; exits non-zero (with a clear message) if anything is unsafe to run.
