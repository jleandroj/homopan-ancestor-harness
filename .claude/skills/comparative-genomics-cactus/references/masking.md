# Repeat Masking

Cactus needs **softmasked** genomes: repeats in lowercase, sequence retained.
Never hardmask (replace with N) for alignment — it deletes real signal. Unmasked
genomes make lastz/SegAlign explode in runtime, so masking is a runtime fix, not a
cosmetic step.

## Check current masking

The preflight reports the lowercase fraction per genome. For mammalian-sized
genomes, expect roughly >40% softmasked; ~0% means masking is missing.

## Option A — RepeatMasker (preferred, lineage-aware)

```bash
RepeatMasker -species <clade> -xsmall -pa <threads> -dir <outdir> genome.fa
# -xsmall  => SOFTmask (lowercase) instead of replacing with N
# output:  genome.fa.masked  (softmasked)
```
Pick `-species` to match the clade (e.g. mammalia, vertebrata). For non-model
genomes, build a de novo library first with RepeatModeler, then feed it via `-lib`.

## Option B — windowmasker (fast fallback, no library)

```bash
windowmasker -mk_counts -in genome.fa -out genome.counts
windowmasker -ustat genome.counts -in genome.fa -outfmt fasta -dust true \
  -out genome.softmask.fa
```
Faster and library-free; less sensitive than RepeatMasker. Acceptable when a
proper repeat library is unavailable; note the tradeoff in the report.

## After masking

- Re-run preflight to confirm masked fraction rose into the expected range.
- Keep the original; write masked genomes to `work/genomes/` and point the seqFile
  at those.
- Record tool, version, library/species, and before/after masked fraction.
