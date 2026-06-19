# Running Progressive Cactus

Always run inside the official pinned container and keep the jobStore/workDir on
fast local scratch. Confirm the exact flags against the version of Cactus in your
container — options evolve between releases.

## Container

```bash
# Singularity / Apptainer (typical on HPC; no root needed)
singularity pull cactus.sif docker://quay.io/comparative-genomics-toolkit/cactus:<tag>
# then prefix commands with:  singularity exec cactus.sif <cmd>
```
Pin `<tag>` to a specific release for reproducibility; record it in the report.

## Mode 1 — single machine

```bash
singularity exec cactus.sif cactus \
  $SCRATCH/jobStore \
  work/seqFile.txt \
  results/alignment.hal \
  --workDir $SCRATCH/cactus_work \
  --maxCores <N> \
  --logFile results/cactus.log
# resume an interrupted run by re-invoking the same command with --restart
```

## Mode 2 — cactus-prepare + SLURM (default on a cluster)

`cactus-prepare` expands the seqFile into an ordered plan of independent
subproblems (one per internal node of the guide tree) that you submit to SLURM.

```bash
singularity exec cactus.sif cactus-prepare work/seqFile.txt \
  --outDir results/ \
  --outSeqFile results/prepared.seqFile \
  --outHal results/alignment.hal \
  --jobStore $SCRATCH/jobStore \
  > results/plan.sh
# plan.sh contains the ordered cactus calls (preprocess -> blast -> align -> convert).
# Submit them respecting dependencies, e.g. with sbatch --dependency=afterok:<jobid>,
# or run via a workflow manager. Independent subtrees run in parallel.
```

### sbatch template (edit resources to your node)

```bash
#!/bin/bash
#SBATCH --job-name=cactus
#SBATCH --partition=<partition>
#SBATCH --cpus-per-task=32
#SBATCH --mem=240G
#SBATCH --time=24:00:00
#SBATCH --output=logs/cactus_%j.out

module load singularity 2>/dev/null || true
export TMPDIR=$L_SCRATCH        # node-local scratch if available
JOBSTORE=$L_SCRATCH/jobStore    # keep tiny-file churn OFF shared filesystems

singularity exec cactus.sif <one step from plan.sh, with --workDir $TMPDIR>
```

Give the lastz/blast steps the most memory. After a run, use `seff <jobid>` to
right-size CPU/RAM for the next submission.

## Mode 3 — GPU (SegAlign)

Use the GPU-enabled container and request a GPU node; pass `--gpu` (verify the flag
for your version). The alignment (SegAlign) step is dramatically faster on large
vertebrate genomes. Everything else is the same.

## Resume / restart

Cactus is checkpointed through its jobStore. To recover from a failure, do NOT
start over: re-run with `--restart` (single machine) or resubmit the remaining
steps of `plan.sh` (prepare mode) pointing at the SAME jobStore. Only delete the
jobStore once the final HAL is validated.

## Cleanup (important on HPC)

The jobStore and workDir contain enormous numbers of small files. After the HAL is
validated, delete them. Leaving them on shared scratch is the typical trigger for
storage/metadata-I/O complaints from research computing.
