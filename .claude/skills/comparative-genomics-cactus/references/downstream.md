# Downstream Analysis from a HAL

Run only after `halValidate` and `halStats` pass. Pick the section matching the
biological question. Verify exact flags against your HAL-tools / PHAST versions.

## Inspect and export

```bash
halStats alignment.hal                      # genomes (incl. ancestors), lengths
halStats --coverage hg38 alignment.hal      # pairwise coverage sanity check
hal2fasta alignment.hal hg38 > hg38.fa       # pull a genome (or an ancestor node)
hal2maf alignment.hal out.maf --refGenome hg38 --noAncestors   # MAF for tools that need it
halLiftover alignment.hal hg38 in.bed mm39 out.bed             # move annotations across genomes
```
MAF is reference-based, so it carries reference bias — state the reference genome.

## Conservation (PHAST)

```bash
# 1) neutral model from putatively neutral sites (e.g. 4-fold degenerate sites)
phyloFit --tree tree.nwk --subst-mod REV --out-root neutral 4d_sites.maf
# 2) per-base conservation + conserved elements
phastCons --target-coverage 0.3 --expected-length 45 \
  --most-conserved most_cons.bed --msa-format MAF out.maf neutral.mod > pp.wig
# 3) site-level conservation / acceleration
phyloP --method LRT --mode CONACC --wig-scores neutral.mod out.maf > phylop.wig
```
State the reference genome and how the neutral model was built. GERP++ is an
alternative for constraint scoring if preferred.

## Ancestral genomes

Internal nodes are reconstructed ancestors. Extract with `hal2fasta alignment.hal
<AncNode>`. Use ancestral sequence to **polarize** changes (ancestral vs derived)
for lineage-specific and introgression analyses.

## Lineage-specific gains/losses & accelerated regions

Compare conservation/branch behavior across the tree using `phyloP --mode ACC`
(acceleration) on the branch of interest to find e.g. lineage-accelerated regions.
For gene/element gains and losses, use `halLiftover`/`halAlignedExtract` to test
presence of a homologous, aligned region in each genome rather than inferring
absence from a failed BLAST.

## Introgression (the archaic-genomics use case)

The HAL gives a clean, reference-free coordinate system to extract homologous
regions across all genomes simultaneously, which is ideal for site-pattern tests.

Workflow:
1. Define the topology for the test: ((P1, P2), P3, Outgroup), where P3 is the
   potential donor (e.g. an archaic genome track) and the outgroup polarizes sites.
2. Extract aligned sites for the four populations from the HAL (via MAF or direct
   HAL queries) and compute D (ABBA-BABA) and/or f-statistics (e.g. f4-ratio,
   fd in windows for localized signal).
3. Block-jackknife across the genome for standard errors; significant D ≠ 0 is
   consistent with gene flow between P3 and P2 (or P1).

Caveats to ALWAYS surface:
- D significant ≠ proof of introgression; incomplete lineage sorting, ancestral
  structure, and reference/mapping bias produce similar patterns.
- Masking artifacts and low-coverage genomes distort site counts.
- The outgroup must be a true outgroup, otherwise polarization is wrong.
- Localized signal (windowed fd) is more informative than a genome-wide D for
  identifying introgressed loci, but is noisier — report window size and counts.

Keep "what the alignment shows" separate from "what it implies biologically," and
never report an introgression result without its caveats and the n of informative
sites.
