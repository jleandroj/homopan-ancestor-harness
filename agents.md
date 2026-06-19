# agents.md -- HomoPan Ancestor Reconstruction Project

> Contract for any LLM agent or human collaborator working in this repository.
> Project root: `~/projects/HomoPan_ancestor/`

---

## 0. Protocolo de Seguridad para Agentes (MANDATORY -- read first)

### 0.1. Obligatoriedad

**BEFORE** proposing, writing, or modifying any file in this repository, the agent **MUST** execute from the project root:

```bash
bash init.sh
```

This applies without exceptions: includes trivial fixes, renames, comments, format changes, script edits, and any other modification to the working tree.

**ENFORCEMENT:** a PreToolUse hook (`.claude/gate_check.sh`, registered in `.claude/settings.json`) **BLOCKS** `Write/Edit/NotebookEdit/Bash` unless `init.sh` has generated a valid gate pass. The gate uses a SHA256 hash of the contract surface (CLAUDE.md + agents.md) -- content-based, not time-based.

### 0.2. Regla de Detencion Absoluta

**IF init.sh FAILS, THE AGENT MUST NOT CONTINUE UNDER ANY CIRCUMSTANCE.**

It is **strictly prohibited** to modify code, scripts, outputs, or any file if `init.sh` returns a non-zero exit code.

This prohibition is absolute:
- Do not "fix what init.sh detected" as a shortcut.
- Do not re-run the script hoping it passes.
- Do not edit init.sh itself to make it pass.
- Do not continue with "the error seems minor" justification.

The only acceptable course of action after a failure is: stop and report (see §0.3).

### 0.3. Failure Report

On init.sh failure, the agent must:

1. **Stop immediately.** No further actions on the repository.
2. **Report to the user:**
   - Exit code
   - Failure reason in natural language
   - Console output **verbatim** (copy exact error lines)
   - Project path
3. **Wait for instructions.**

Format:
```
init.sh failed -- work BLOCKED.

Project root: ~/projects/HomoPan_ancestor/
Exit code: 1
Summary: <one-line description>

Console output (verbatim):
<paste exact [FAIL] lines and STOP banner>

I will not modify any file until you tell me how to proceed.
```

### 0.4. What init.sh checks

1. `agents.md` exists and contains mandatory markers.
2. `CLAUDE.md` exists.
3. Essential directories exist (genomes/, scripts/).
4. Container SIF exists.
5. `agents.md` contains: `"Protocolo de Seguridad para Agentes"`, `"Regla de Detencion Absoluta"`, `"init.sh"`.
6. Generates SHA256 gate pass from contract surface.

---

## 1. Project Context

This project reconstructs the **Homo-Pan common ancestor** genome using progressive Cactus whole-genome alignment of 5 primate species:

| Species | Accession | Genome Size |
|---------|-----------|-------------|
| Homo sapiens | GCA_009914755.4 | 3.12 Gbp |
| Pan paniscus (bonobo) | GCF_029289425.2 | 3.24 Gbp |
| Pan troglodytes (chimpanzee) | GCF_028858775.2 | 3.18 Gbp |
| Gorilla gorilla gorilla | GCF_029281585.2 | 3.55 Gbp |
| Pongo abelii (orangutan) | GCF_028885655.2 | 3.26 Gbp |

**Tree topology:**
```
(((homo_sapiens,(pan_paniscus,pan_troglodytes)Pan)Anc_HomoPan,gorilla_gorilla_gorilla)Homininae,pongo_abelii)Root;
```

**Target ancestor nodes:** Anc_HomoPan, Pan, Homininae, Root

---

## 2. Architecture

### 2.1. Pipeline Flow

```
00_check_env -> 01_validate_fastas -> 02_make_test_fastas -> 03_make_seqfiles
  -> 04_run_test_cactus -> 05_validate_test_hal
  -> 06_run_full_cactus -> 07_validate_full_hal -> 08_extract_ancestors
  -> 09_make_report -> 10_qc_summary
```

### 2.2. Key Design Decisions

1. **Container wrapping**: All Cactus/HAL tools run via `apptainer exec` wrappers in `config.sh`.
2. **No seqkit**: Replaced by `samtools faidx` region extraction (seqkit unavailable).
3. **Idempotency**: Each step creates `targets/STEP.done`. Orchestrators skip completed steps.
4. **Content-based gate**: SHA256 of contract surface, not time-based.
5. **Path derivation**: All paths derived from `BASH_SOURCE`, never hardcoded.
6. **Cactus v3**: Uses `--binariesMode local` and `--batchSystem single_machine` (underscore).
7. **Host samtools**: version 1.21 preferred over container's 1.11.
8. **Alternate workdir**: Set `HOMOPAN_WORKDIR=/mnt/s1/homopan_work` for overflow.

---

## 3. Rules

### 3.1. Output Language

All outputs, reports, and documentation in **English**. Comments in code in English. User communication may be in Spanish or English per user preference.

### 3.2. Never Silently Fix

If a script fails, a file is missing, or an output seems wrong:
- **Report the problem exactly.**
- **Do NOT guess a fix and apply it.**
- **Wait for user instructions.**

### 3.3. Never Assume Defaults

For any pipeline parameter (mode, region, species subset, disk target), ask the user. Do not assume test vs. full, do not assume which ancestors to extract.

### 3.4. No External Uploads

Genome data and results stay on the local machine. No uploads to external services.

### 3.5. Biological Caveats

Always report these caveats when presenting results:
1. 1 Mb test alignment is technical-only (not biologically meaningful).
2. Ancestral sequences are **inferred**, not observed genomes.
3. Assembly quality affects reconstruction accuracy.
4. Target-region analysis requires coordinate and orthology validation.
5. Never claim biological conclusions from technical validation alone.

---

## 4. Disk Management

| Path | Size | Purpose |
|------|------|---------|
| `/home` (/) | 916 GB total, ~377 GB free | Primary disk |
| `/mnt/s1` | 7.3 TB total, ~527 GB free | Overflow disk |
| `work/` | ~127 GB (old jobstores) | Candidate for cleanup |

For full Cactus run, use `HOMOPAN_WORKDIR=/mnt/s1/homopan_work` if primary disk is tight.

---

## 5. Compute Resources

| Resource | Value |
|----------|-------|
| CPU | 2x Xeon E5-2673 v4, 40 cores @ 2.3 GHz |
| RAM | 1.0 TiB |
| GPU | Quadro P5000 16 GB (not used by Cactus) |
| Container | Apptainer 1.4.5 + cactus_v3.0.1.sif |
| SLURM | Not configured (template script only) |

---

## 6. File Inventory

### Input Files
- `genomes/*.fa` + `.fai` -- 5 primate genomes (~16 GB total)
- `accessions.tsv` -- species and NCBI accessions
- `cactus_v3.0.1.sif` -- Cactus container (425 MB)

### Generated Files
- `primates.seqfile` / `primates.test.seqfile` -- Cactus input
- `test_genomes/*.test1Mb.fa` -- 1 Mb test FASTAs
- `results/test/primates.test.hal` -- test alignment
- `results/full/primates.full.hal` -- full alignment
- `results/ancestors/*.fa` -- extracted ancestor FASTAs
- `results/reports/HomoPan_ancestor_report.md` -- final report
- `qc/*` -- validation outputs and checksums
- `targets/*.done` -- idempotency markers
- `logs/*` -- execution logs and bitacora

---

## 7. Tools Available

| Tool | Location | Version |
|------|----------|---------|
| samtools | host (miniconda3) | 1.21 |
| apptainer | /usr/bin | 1.4.5 |
| cactus | container | v3.0.1 (9.1.2) |
| halStats | container | v2.2 |
| halValidate | container | v2.2 |
| hal2fasta | container | v2.2 |
| bedtools | host | v2.27.1 |
| jq | conda env homopan_ancestor | 1.8.1 |
| python3 | host (miniconda3) | 3.12.2 |

---

## 8. Specialized Agents

Task-specific agents live in `.claude/agents/`. Each re-states the safety protocol.

| Agent | File | Purpose |
|-------|------|---------|
| homopan-preflight | `.claude/agents/homopan-preflight.md` | Read-only pre-flight checks |
| homopan-pipeline | `.claude/agents/homopan-pipeline.md` | Execute test or full pipeline |
| homopan-validator | `.claude/agents/homopan-validator.md` | Validate HAL outputs |
| homopan-improver | `.claude/agents/homopan-improver.md` | Propose improvements (never auto-apply) |
| homopan-doc-keeper | `.claude/agents/homopan-doc-keeper.md` | Maintain documentation |

### Delegation Rules

- **Pre-flight**: Always run before starting work.
- **Pipeline**: User must explicitly request test or full mode.
- **Validator**: Run after pipeline completes.
- **Improver**: Only proposes, never applies.
- **Doc-keeper**: Run after significant pipeline changes.
