# Inputs and Tree Validation

Read this at Step 0/2. Goal: guarantee the alignment can run before spending compute.

## Newick species tree

Cactus needs a **rooted** tree with branch lengths in substitutions/site, one leaf
per input genome, terminated by `;`. Internal node labels (ancestor names) are
optional but useful — Cactus reconstructs those ancestors.

Requirements:
- Rooted. If your tree is unrooted, root it on a known outgroup before running.
- Branch lengths present and non-negative. Missing lengths → estimate them
  (e.g. with a few BUSCO/marker genes + IQ-TREE) rather than guessing.
- Binary (bifurcating) is safest. Resolve hard polytomies (multifurcations);
  near-zero lengths for uncertain splits are acceptable.
- Leaf names match seqFile genome names EXACTLY: `[A-Za-z0-9_]`, no spaces,
  no duplicates.

Useful tools: `ete3`, `dendropy`, or `nw_*` (newick_utils) to reroot
(`nw_reroot`), prune, or print (`nw_display`). IQ-TREE to build/estimate a tree
from markers. Always keep the original tree; write the cleaned one to `work/`.

## Genome FASTAs

- One FASTA per genome; absolute paths in the seqFile.
- **Softmasked** (repeats lowercase). See `masking.md`.
- Clean sequence names; avoid spaces in headers.
- Sanity stats to inspect (preflight prints these): #sequences, total length, N50,
  %N. Flag anything that looks like raw reads, is suspiciously tiny, or is mostly N.

## Name harmonization

The single most common late failure is a name mismatch between tree leaves and
seqFile genome lines. The preflight does an exact set comparison and refuses to
pass if they differ. Fix names in BOTH the tree and the seqFile, not just one.

## Choosing genomes / outgroup

For conservation and especially for introgression/ABBA-BABA later, include an
appropriate **outgroup** so changes can be polarized. Document which genome is the
outgroup. More closely spaced genomes give higher alignment coverage but more
compute; balance taxon sampling against resources.
