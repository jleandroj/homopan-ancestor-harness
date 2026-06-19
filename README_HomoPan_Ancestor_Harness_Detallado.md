# README — HomoPan Ancestor Harness detallado

## 0. Propósito del archivo

Este archivo es una guía altamente detallada para crear un **harness reproducible** para el proyecto:

```bash
~/projects/HomoPan_ancestor
```

El harness debe ayudar a responder esta pregunta:

> ¿Podemos reconstruir y validar técnicamente el ancestro **Homo–Pan** usando cinco genomas de primates: humano, bonobo, chimpancé, gorila y orangután?

El resultado principal esperado es:

```bash
results/ancestors/Anc_HomoPan.fa
```

Ese archivo será la secuencia ancestral inferida para el nodo **Anc_HomoPan**.

---

## 1. Idea general del pipeline

El pipeline completo es:

```text
FASTA completos de 5 especies
        ↓
validar archivos FASTA
        ↓
indexar FASTA con samtools faidx
        ↓
crear FASTA test de 1 Mb
        ↓
crear seqfile test y seqfile full
        ↓
validar formato de seqfiles
        ↓
correr Cactus test
        ↓
validar HAL test con halValidate y halStats
        ↓
extraer Anc_HomoPan test con hal2fasta
        ↓
correr Cactus full
        ↓
validar HAL full
        ↓
extraer Anc_HomoPan, Pan, Homininae y Root
        ↓
crear reporte final
```

---

## 2. Especies usadas

Usar solamente estas cinco especies:

| Especie | Nombre en el pipeline | Assembly accession |
|---|---|---|
| Humano | `homo_sapiens` | `GCA_009914755.4` |
| Bonobo | `pan_paniscus` | `GCF_029289425.2` |
| Chimpancé | `pan_troglodytes` | `GCF_028858775.2` |
| Gorila | `gorilla_gorilla_gorilla` | `GCF_029281585.2` |
| Orangután | `pongo_abelii` | `GCF_028885655.2` |

**No usar `macaca` en este pipeline.**

---

## 3. Árbol filogenético

Usar este árbol Newick:

```text
(((homo_sapiens,(pan_paniscus,pan_troglodytes)Pan)Anc_HomoPan,gorilla_gorilla_gorilla)Homininae,pongo_abelii)Root;
```

Nodos internos:

| Nodo | Significado |
|---|---|
| `Pan` | Ancestro de bonobo y chimpancé |
| `Anc_HomoPan` | Ancestro de humano + Pan |
| `Homininae` | Ancestro de humano/Pan/gorila |
| `Root` | Raíz usando orangután como outgroup |

Nodo principal:

```text
Anc_HomoPan
```

---

## 4. Estructura esperada del proyecto

Desde el proyecto:

```bash
cd ~/projects/HomoPan_ancestor
```

El harness debe crear esta estructura:

```text
HomoPan_ancestor/
├── accessions.tsv
├── primates.test.seqfile
├── primates.seqfile
├── genomes/
│   ├── homo_sapiens.fa
│   ├── pan_paniscus.fa
│   ├── pan_troglodytes.fa
│   ├── gorilla_gorilla_gorilla.fa
│   └── pongo_abelii.fa
├── test_genomes/
├── scripts/
├── logs/
├── qc/
├── targets/
└── results/
    ├── test/
    ├── full/
    ├── ancestors/
    ├── regions/
    └── reports/
```

Crear directorios:

```bash
mkdir -p \
  scripts \
  logs \
  qc \
  targets \
  test_genomes \
  results/test \
  results/full \
  results/ancestors \
  results/regions \
  results/reports
```

---

## 5. Inputs esperados

Los FASTA completos deben existir aquí:

```bash
genomes/homo_sapiens.fa
genomes/pan_paniscus.fa
genomes/pan_troglodytes.fa
genomes/gorilla_gorilla_gorilla.fa
genomes/pongo_abelii.fa
```

Cada FASTA debe cumplir:

1. Existe.
2. No está vacío.
3. No está corrupto.
4. Puede indexarse con `samtools faidx`.
5. Su `.fai` queda creado correctamente.

---

## 6. Crear archivo de accesiones

Crear:

```bash
cat > accessions.tsv << 'EOF'
homo_sapiens GCA_009914755.4
pan_paniscus GCF_029289425.2
pan_troglodytes GCF_028858775.2
gorilla_gorilla_gorilla GCF_029281585.2
pongo_abelii GCF_028885655.2
EOF
```

Este archivo es metadata. Cactus no lo necesita directamente, pero sirve para reproducibilidad.

---

## 7. Reglas del harness

Cada script debe comenzar con:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Esto significa:

- `-e`: si un comando falla, el script se detiene.
- `-u`: si una variable no existe, el script se detiene.
- `-o pipefail`: si falla una parte de un pipe, el script falla.

El harness no debe adivinar. Si falta algo, debe parar con un mensaje claro.

---

## 8. Lista de scripts que el harness debe crear

Crear estos scripts:

```bash
scripts/00_check_env.sh
scripts/01_validate_fastas.sh
scripts/02_make_test_fastas.sh
scripts/03_make_seqfiles.sh
scripts/04_run_test_cactus.sh
scripts/05_validate_test_hal.sh
scripts/06_run_full_cactus.sh
scripts/06_run_full_cactus_slurm.sh
scripts/07_validate_full_hal.sh
scripts/08_extract_ancestors.sh
scripts/09_make_report.sh
scripts/10_qc_summary.sh
scripts/run_all_test.sh
scripts/run_all_full.sh
```

---

# PARTE A — SCRIPTS DEL HARNESS

---

## 9. Script 00 — revisar ambiente

Crear:

```bash
cat > scripts/00_check_env.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p scripts logs qc targets test_genomes results/test results/full results/ancestors results/regions results/reports

echo "========================================"
echo "Checking required tools"
echo "========================================"

REQUIRED_TOOLS=(
  cactus
  halStats
  halValidate
  hal2fasta
  samtools
  seqkit
  awk
  grep
  sed
)

for TOOL in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$TOOL" >/dev/null 2>&1; then
    echo "ERROR: missing required tool: $TOOL"
    exit 1
  fi
  echo "OK: $TOOL -> $(command -v "$TOOL")"
done

echo ""
echo "Cactus version:"
cactus --version || true

echo ""
echo "samtools version:"
samtools --version | head -n 1

echo ""
echo "seqkit version:"
seqkit version

echo ""
echo "Environment check finished successfully."
EOF

chmod +x scripts/00_check_env.sh
```

Ejecutar:

```bash
./scripts/00_check_env.sh | tee logs/00_check_env.log
```

Criterio de éxito:

```text
Environment check finished successfully.
```

---

## 10. Script 01 — validar FASTA completos

Crear:

```bash
cat > scripts/01_validate_fastas.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p qc logs

SPECIES=(
  homo_sapiens
  pan_paniscus
  pan_troglodytes
  gorilla_gorilla_gorilla
  pongo_abelii
)

: > qc/fasta_check.summary.txt

for ID in "${SPECIES[@]}"; do
  FA="genomes/${ID}.fa"

  echo "========================================"
  echo "Checking $ID"
  echo "File: $FA"

  if [[ ! -e "$FA" ]]; then
    echo "ERROR: FASTA does not exist: $FA"
    exit 1
  fi

  if [[ ! -s "$FA" ]]; then
    echo "ERROR: FASTA is empty: $FA"
    exit 1
  fi

  echo "Indexing with samtools faidx..."
  samtools faidx "$FA"

  if [[ ! -s "${FA}.fai" ]]; then
    echo "ERROR: FASTA index was not created: ${FA}.fai"
    exit 1
  fi

  NSEQ=$(wc -l < "${FA}.fai")
  TOTAL_BP=$(awk '{sum += $2} END {print sum}' "${FA}.fai")

  echo "Species: $ID" >> qc/fasta_check.summary.txt
  echo "FASTA: $FA" >> qc/fasta_check.summary.txt
  echo "Number of sequences: $NSEQ" >> qc/fasta_check.summary.txt
  echo "Total bp: $TOTAL_BP" >> qc/fasta_check.summary.txt
  echo "Top 10 sequences:" >> qc/fasta_check.summary.txt
  cut -f1,2 "${FA}.fai" | head -n 10 >> qc/fasta_check.summary.txt
  echo "" >> qc/fasta_check.summary.txt

  echo "OK: $ID has $NSEQ sequences and $TOTAL_BP bp"
done

echo "========================================"
echo "All full FASTA files are valid and indexed."
EOF

chmod +x scripts/01_validate_fastas.sh
```

Ejecutar:

```bash
./scripts/01_validate_fastas.sh | tee logs/01_validate_fastas.log
```

Criterio de éxito:

```text
All full FASTA files are valid and indexed.
```

---

## 11. Script 02 — crear FASTA test de 1 Mb

Crear:

```bash
cat > scripts/02_make_test_fastas.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

SPECIES=(
  homo_sapiens
  pan_paniscus
  pan_troglodytes
  gorilla_gorilla_gorilla
  pongo_abelii
)

rm -rf test_genomes
mkdir -p test_genomes qc

: > qc/test_fasta_check.summary.txt

for ID in "${SPECIES[@]}"; do
  INFA="genomes/${ID}.fa"
  OUTFA="test_genomes/${ID}.test1Mb.fa"

  echo "========================================"
  echo "Creating test FASTA for $ID"
  echo "Input: $INFA"
  echo "Output: $OUTFA"

  if [[ ! -s "$INFA" ]]; then
    echo "ERROR: missing input FASTA: $INFA"
    exit 1
  fi

  seqkit head -n 1 "$INFA" \
    | seqkit subseq -r 1:1000000 \
    | seqkit seq -i \
    > "$OUTFA"

  if [[ ! -s "$OUTFA" ]]; then
    echo "ERROR: failed to create $OUTFA"
    exit 1
  fi

  samtools faidx "$OUTFA"

  NSEQ=$(wc -l < "${OUTFA}.fai")
  TOTAL_BP=$(awk '{sum += $2} END {print sum}' "${OUTFA}.fai")

  echo "Species: $ID" >> qc/test_fasta_check.summary.txt
  echo "Test FASTA: $OUTFA" >> qc/test_fasta_check.summary.txt
  echo "Number of sequences: $NSEQ" >> qc/test_fasta_check.summary.txt
  echo "Total bp: $TOTAL_BP" >> qc/test_fasta_check.summary.txt
  cat "${OUTFA}.fai" >> qc/test_fasta_check.summary.txt
  echo "" >> qc/test_fasta_check.summary.txt

  echo "OK: created $OUTFA with $TOTAL_BP bp"
done

echo "========================================"
echo "All test FASTA files created successfully."
EOF

chmod +x scripts/02_make_test_fastas.sh
```

Ejecutar:

```bash
./scripts/02_make_test_fastas.sh | tee logs/02_make_test_fastas.log
```

Criterio de éxito:

```text
All test FASTA files created successfully.
```

**Advertencia:** este test de 1 Mb es técnico. No es evidencia biológica fuerte porque el primer contig de cada especie no necesariamente representa la misma región ortóloga.

---

## 12. Script 03 — crear seqfiles

Crear:

```bash
cat > scripts/03_make_seqfiles.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p qc

TREE="(((homo_sapiens,(pan_paniscus,pan_troglodytes)Pan)Anc_HomoPan,gorilla_gorilla_gorilla)Homininae,pongo_abelii)Root;"

cat > primates.test.seqfile << EOF2
$TREE
homo_sapiens $PWD/test_genomes/homo_sapiens.test1Mb.fa
pan_paniscus $PWD/test_genomes/pan_paniscus.test1Mb.fa
pan_troglodytes $PWD/test_genomes/pan_troglodytes.test1Mb.fa
gorilla_gorilla_gorilla $PWD/test_genomes/gorilla_gorilla_gorilla.test1Mb.fa
pongo_abelii $PWD/test_genomes/pongo_abelii.test1Mb.fa
EOF2

cat > primates.seqfile << EOF2
$TREE
homo_sapiens $PWD/genomes/homo_sapiens.fa
pan_paniscus $PWD/genomes/pan_paniscus.fa
pan_troglodytes $PWD/genomes/pan_troglodytes.fa
gorilla_gorilla_gorilla $PWD/genomes/gorilla_gorilla_gorilla.fa
pongo_abelii $PWD/genomes/pongo_abelii.fa
EOF2

: > qc/seqfile_check.txt

echo "Checking primates.test.seqfile" | tee -a qc/seqfile_check.txt
cat -n primates.test.seqfile | tee -a qc/seqfile_check.txt

echo "" | tee -a qc/seqfile_check.txt
echo "Column check for primates.test.seqfile" | tee -a qc/seqfile_check.txt
awk 'NR>1{print NF, $1, $2}' primates.test.seqfile | tee -a qc/seqfile_check.txt

echo "" | tee -a qc/seqfile_check.txt
echo "Checking primates.seqfile" | tee -a qc/seqfile_check.txt
cat -n primates.seqfile | tee -a qc/seqfile_check.txt

echo "" | tee -a qc/seqfile_check.txt
echo "Column check for primates.seqfile" | tee -a qc/seqfile_check.txt
awk 'NR>1{print NF, $1, $2}' primates.seqfile | tee -a qc/seqfile_check.txt

BAD_TEST=$(awk 'NR>1 && NF != 2 {count++} END{print count+0}' primates.test.seqfile)
BAD_FULL=$(awk 'NR>1 && NF != 2 {count++} END{print count+0}' primates.seqfile)

if [[ "$BAD_TEST" -ne 0 ]]; then
  echo "ERROR: primates.test.seqfile has lines with != 2 columns"
  exit 1
fi

if [[ "$BAD_FULL" -ne 0 ]]; then
  echo "ERROR: primates.seqfile has lines with != 2 columns"
  exit 1
fi

for FA in $(awk 'NR>1{print $2}' primates.test.seqfile); do
  if [[ ! -s "$FA" ]]; then
    echo "ERROR: missing FASTA in test seqfile: $FA"
    exit 1
  fi
done

for FA in $(awk 'NR>1{print $2}' primates.seqfile); do
  if [[ ! -s "$FA" ]]; then
    echo "ERROR: missing FASTA in full seqfile: $FA"
    exit 1
  fi
done

echo "Seqfiles are valid."
EOF

chmod +x scripts/03_make_seqfiles.sh
```

Ejecutar:

```bash
./scripts/03_make_seqfiles.sh | tee logs/03_make_seqfiles.log
```

Criterio de éxito:

```text
Seqfiles are valid.
```

---

## 13. Script 04 — correr Cactus test

Crear:

```bash
cat > scripts/04_run_test_cactus.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p results/test logs

SEQFILE="primates.test.seqfile"
JOBSTORE="js-test"
OUTHAL="results/test/primates.test.hal"

if [[ ! -s "$SEQFILE" ]]; then
  echo "ERROR: missing seqfile: $SEQFILE"
  exit 1
fi

rm -rf "$JOBSTORE" "$OUTHAL"

echo "Running Cactus test..."
echo "Seqfile: $SEQFILE"
echo "Jobstore: $JOBSTORE"
echo "Output HAL: $OUTHAL"

cactus "$JOBSTORE" "$SEQFILE" "$OUTHAL" \
  --batchSystem singleMachine \
  --realTimeLogging

if [[ ! -s "$OUTHAL" ]]; then
  echo "ERROR: Cactus finished but HAL was not created: $OUTHAL"
  exit 1
fi

echo "Cactus test finished successfully."
EOF

chmod +x scripts/04_run_test_cactus.sh
```

Ejecutar:

```bash
./scripts/04_run_test_cactus.sh | tee logs/04_run_test_cactus.log
```

Criterio de éxito:

```text
Cactus test finished successfully.
```

---

## 14. Script 05 — validar HAL test

Crear:

```bash
cat > scripts/05_validate_test_hal.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p qc results/ancestors

HAL="results/test/primates.test.hal"
ANC="results/ancestors/Anc_HomoPan.test.fa"

if [[ ! -s "$HAL" ]]; then
  echo "ERROR: missing test HAL: $HAL"
  exit 1
fi

echo "Validating test HAL..."
halValidate "$HAL" | tee qc/test_halValidate.txt

echo "Getting HAL stats..."
halStats "$HAL" | tee qc/test_halStats.txt

echo "Getting HAL tree..."
halStats --tree "$HAL" | tee qc/test_halTree.txt

echo "Getting HAL genomes..."
halStats --genomes "$HAL" | tee qc/test_halGenomes.txt

echo "Checking that Anc_HomoPan exists in HAL..."
if ! halStats --genomes "$HAL" | grep -w "Anc_HomoPan" >/dev/null 2>&1; then
  echo "ERROR: Anc_HomoPan not found in HAL genomes."
  exit 1
fi

echo "Extracting Anc_HomoPan test FASTA..."
hal2fasta "$HAL" Anc_HomoPan > "$ANC"

if [[ ! -s "$ANC" ]]; then
  echo "ERROR: failed to extract $ANC"
  exit 1
fi

samtools faidx "$ANC"

echo "Anc_HomoPan test FASTA extracted successfully."
EOF

chmod +x scripts/05_validate_test_hal.sh
```

Ejecutar:

```bash
./scripts/05_validate_test_hal.sh | tee logs/05_validate_test_hal.log
```

Criterio de éxito:

```text
Anc_HomoPan test FASTA extracted successfully.
```

---

## 15. Script 06 — correr Cactus completo local/singleMachine

Crear:

```bash
cat > scripts/06_run_full_cactus.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p results/full logs

SEQFILE="primates.seqfile"
JOBSTORE="js-full"
OUTHAL="results/full/primates.full.hal"

if [[ ! -s "$SEQFILE" ]]; then
  echo "ERROR: missing seqfile: $SEQFILE"
  exit 1
fi

rm -rf "$JOBSTORE" "$OUTHAL"

echo "Running full Cactus alignment..."
echo "Seqfile: $SEQFILE"
echo "Jobstore: $JOBSTORE"
echo "Output HAL: $OUTHAL"

cactus "$JOBSTORE" "$SEQFILE" "$OUTHAL" \
  --batchSystem singleMachine \
  --realTimeLogging

if [[ ! -s "$OUTHAL" ]]; then
  echo "ERROR: Cactus finished but full HAL was not created: $OUTHAL"
  exit 1
fi

echo "Full Cactus run finished successfully."
EOF

chmod +x scripts/06_run_full_cactus.sh
```

Ejecutar:

```bash
./scripts/06_run_full_cactus.sh | tee logs/06_run_full_cactus.log
```

Advertencia: este paso puede ser pesado para genomas completos.

---

## 16. Script 06 opcional — SLURM

Crear:

```bash
cat > scripts/06_run_full_cactus_slurm.sh << 'EOF'
#!/usr/bin/env bash
#SBATCH --job-name=HomoPan_Cactus
#SBATCH --partition=normal
#SBATCH --cpus-per-task=20
#SBATCH --mem=128G
#SBATCH --time=48:00:00
#SBATCH --output=logs/06_run_full_cactus_slurm.%j.out
#SBATCH --error=logs/06_run_full_cactus_slurm.%j.err

set -euo pipefail

cd ~/projects/HomoPan_ancestor

mkdir -p results/full logs

SEQFILE="primates.seqfile"
JOBSTORE="js-full"
OUTHAL="results/full/primates.full.hal"

if [[ ! -s "$SEQFILE" ]]; then
  echo "ERROR: missing seqfile: $SEQFILE"
  exit 1
fi

rm -rf "$JOBSTORE" "$OUTHAL"

echo "Running full Cactus alignment on SLURM..."

cactus "$JOBSTORE" "$SEQFILE" "$OUTHAL" \
  --batchSystem singleMachine \
  --realTimeLogging

if [[ ! -s "$OUTHAL" ]]; then
  echo "ERROR: full HAL was not created: $OUTHAL"
  exit 1
fi

echo "Full Cactus SLURM run finished successfully."
EOF

chmod +x scripts/06_run_full_cactus_slurm.sh
```

Ejecutar:

```bash
sbatch scripts/06_run_full_cactus_slurm.sh
```

---

## 17. Script 07 — validar HAL completo

Crear:

```bash
cat > scripts/07_validate_full_hal.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p qc

HAL="results/full/primates.full.hal"

if [[ ! -s "$HAL" ]]; then
  echo "ERROR: missing full HAL: $HAL"
  exit 1
fi

echo "Validating full HAL..."
halValidate "$HAL" | tee qc/full_halValidate.txt

echo "Getting full HAL stats..."
halStats "$HAL" | tee qc/full_halStats.txt

echo "Getting full HAL tree..."
halStats --tree "$HAL" | tee qc/full_halTree.txt

echo "Getting full HAL genomes..."
halStats --genomes "$HAL" | tee qc/full_halGenomes.txt

echo "Checking required nodes..."
for NODE in Anc_HomoPan Pan Homininae Root; do
  if ! halStats --genomes "$HAL" | grep -w "$NODE" >/dev/null 2>&1; then
    echo "ERROR: required node not found in HAL: $NODE"
    exit 1
  fi
  echo "OK: found node $NODE"
done

echo "Full HAL validation finished successfully."
EOF

chmod +x scripts/07_validate_full_hal.sh
```

Ejecutar:

```bash
./scripts/07_validate_full_hal.sh | tee logs/07_validate_full_hal.log
```

---

## 18. Script 08 — extraer ancestros

Crear:

```bash
cat > scripts/08_extract_ancestors.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p results/ancestors

HAL="results/full/primates.full.hal"

if [[ ! -s "$HAL" ]]; then
  echo "ERROR: missing full HAL: $HAL"
  exit 1
fi

NODES=(
  Anc_HomoPan
  Pan
  Homininae
  Root
)

for NODE in "${NODES[@]}"; do
  OUTFA="results/ancestors/${NODE}.fa"

  echo "========================================"
  echo "Extracting ancestral node: $NODE"
  echo "Output: $OUTFA"

  hal2fasta "$HAL" "$NODE" > "$OUTFA"

  if [[ ! -s "$OUTFA" ]]; then
    echo "ERROR: failed to extract $OUTFA"
    exit 1
  fi

  samtools faidx "$OUTFA"

  NSEQ=$(wc -l < "${OUTFA}.fai")
  TOTAL_BP=$(awk '{sum += $2} END {print sum}' "${OUTFA}.fai")

  echo "OK: $NODE extracted with $NSEQ sequences and $TOTAL_BP bp"
done

echo "All ancestral FASTA files extracted successfully."
EOF

chmod +x scripts/08_extract_ancestors.sh
```

Ejecutar:

```bash
./scripts/08_extract_ancestors.sh | tee logs/08_extract_ancestors.log
```

---

## 19. Script 09 — crear reporte final

Crear:

```bash
cat > scripts/09_make_report.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p results/reports

REPORT="results/reports/HomoPan_ancestor_report.md"
TREE=$(head -n 1 primates.seqfile 2>/dev/null || echo "TREE_NOT_AVAILABLE")

cat > "$REPORT" << EOF2
# Homo-Pan Ancestral Reconstruction Report

## Main question

Can we reconstruct and technically validate the Homo-Pan ancestral sequence using five primate genomes?

## Species used

| Species | FASTA |
|---|---|
| homo_sapiens | genomes/homo_sapiens.fa |
| pan_paniscus | genomes/pan_paniscus.fa |
| pan_troglodytes | genomes/pan_troglodytes.fa |
| gorilla_gorilla_gorilla | genomes/gorilla_gorilla_gorilla.fa |
| pongo_abelii | genomes/pongo_abelii.fa |

## Tree

\`\`\`text
$TREE
\`\`\`

## Target ancestral node

\`\`\`text
Anc_HomoPan
\`\`\`

## FASTA validation summary

\`\`\`text
$(cat qc/fasta_check.summary.txt 2>/dev/null || echo "Not available")
\`\`\`

## Test FASTA summary

\`\`\`text
$(cat qc/test_fasta_check.summary.txt 2>/dev/null || echo "Not available")
\`\`\`

## Test HAL validation

\`\`\`text
$(cat qc/test_halValidate.txt 2>/dev/null || echo "Not available")
\`\`\`

## Test HAL stats

\`\`\`text
$(cat qc/test_halStats.txt 2>/dev/null || echo "Not available")
\`\`\`

## Test HAL tree

\`\`\`text
$(cat qc/test_halTree.txt 2>/dev/null || echo "Not available")
\`\`\`

## Full HAL validation

\`\`\`text
$(cat qc/full_halValidate.txt 2>/dev/null || echo "Not available")
\`\`\`

## Full HAL stats

\`\`\`text
$(cat qc/full_halStats.txt 2>/dev/null || echo "Not available")
\`\`\`

## Full HAL tree

\`\`\`text
$(cat qc/full_halTree.txt 2>/dev/null || echo "Not available")
\`\`\`

## Extracted ancestors

\`\`\`text
$(ls -lh results/ancestors/*.fa 2>/dev/null || echo "No ancestor FASTA files found")
\`\`\`

## Technical interpretation

The reconstruction is technically valid if:

1. All input FASTA files exist and are indexed.
2. The Cactus test run completes.
3. The test HAL passes halValidate.
4. Anc_HomoPan can be extracted from the test HAL.
5. The full Cactus run completes.
6. The full HAL passes halValidate.
7. Anc_HomoPan can be extracted from the full HAL.

## Caveats

The 1 Mb test is a technical test only. It should not be used as strong biological evidence unless the regions are confirmed to be orthologous.

The full-genome HAL is the correct output for biological interpretation.

Ancestral FASTA sequences are inferred. They are not observed genomes.

Assembly quality, repeats, gaps, segmental duplications, and phylogenetic tree choice can affect ancestral inference.

## Final answer template

If all validation steps pass:

> Yes. The Homo-Pan ancestral reconstruction is technically valid because Cactus completed successfully, halValidate passed, the expected tree and genomes are present in the HAL file, and Anc_HomoPan.fa was extracted successfully.

If only the 1 Mb test passed:

> The pipeline is technically working, but the biological reconstruction is not complete yet. The 1 Mb run validates the harness and Cactus setup, but the full-genome HAL is still required for biological interpretation.
EOF2

echo "Report written to $REPORT"
EOF

chmod +x scripts/09_make_report.sh
```

Ejecutar:

```bash
./scripts/09_make_report.sh | tee logs/09_make_report.log
```

---

## 20. Script 10 — resumen QC

Crear:

```bash
cat > scripts/10_qc_summary.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo "HomoPan QC Summary"
echo "========================================"

echo ""
echo "Project directory:"
pwd

echo ""
echo "Seqfiles:"
ls -lh primates.test.seqfile primates.seqfile 2>/dev/null || true

echo ""
echo "Input FASTA:"
ls -lh genomes/*.fa 2>/dev/null || true

echo ""
echo "Test FASTA:"
ls -lh test_genomes/*.fa 2>/dev/null || true

echo ""
echo "HAL outputs:"
ls -lh results/test/*.hal results/full/*.hal 2>/dev/null || true

echo ""
echo "Ancestor FASTA outputs:"
ls -lh results/ancestors/*.fa 2>/dev/null || true

echo ""
echo "Report:"
ls -lh results/reports/HomoPan_ancestor_report.md 2>/dev/null || true

echo ""
echo "HAL genomes test:"
cat qc/test_halGenomes.txt 2>/dev/null || echo "Not available"

echo ""
echo "HAL genomes full:"
cat qc/full_halGenomes.txt 2>/dev/null || echo "Not available"

echo "========================================"
echo "QC summary finished."
EOF

chmod +x scripts/10_qc_summary.sh
```

Ejecutar:

```bash
./scripts/10_qc_summary.sh | tee logs/10_qc_summary.log
```

---

## 21. Script run_all_test.sh

Crear:

```bash
cat > scripts/run_all_test.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p logs

./scripts/00_check_env.sh | tee logs/00_check_env.log
./scripts/01_validate_fastas.sh | tee logs/01_validate_fastas.log
./scripts/02_make_test_fastas.sh | tee logs/02_make_test_fastas.log
./scripts/03_make_seqfiles.sh | tee logs/03_make_seqfiles.log
./scripts/04_run_test_cactus.sh | tee logs/04_run_test_cactus.log
./scripts/05_validate_test_hal.sh | tee logs/05_validate_test_hal.log
./scripts/09_make_report.sh | tee logs/09_make_report.log
./scripts/10_qc_summary.sh | tee logs/10_qc_summary.log

echo "Test harness completed successfully."
EOF

chmod +x scripts/run_all_test.sh
```

Ejecutar:

```bash
bash scripts/run_all_test.sh
```

---

## 22. Script run_all_full.sh

Crear:

```bash
cat > scripts/run_all_full.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p logs

./scripts/00_check_env.sh | tee logs/00_check_env.log
./scripts/01_validate_fastas.sh | tee logs/01_validate_fastas.log
./scripts/03_make_seqfiles.sh | tee logs/03_make_seqfiles.log
./scripts/06_run_full_cactus.sh | tee logs/06_run_full_cactus.log
./scripts/07_validate_full_hal.sh | tee logs/07_validate_full_hal.log
./scripts/08_extract_ancestors.sh | tee logs/08_extract_ancestors.log
./scripts/09_make_report.sh | tee logs/09_make_report.log
./scripts/10_qc_summary.sh | tee logs/10_qc_summary.log

echo "Full harness completed successfully."
EOF

chmod +x scripts/run_all_full.sh
```

Ejecutar:

```bash
bash scripts/run_all_full.sh
```

---

# PARTE B — EJECUCIÓN DEL PIPELINE

---

## 23. Preparar proyecto

```bash
cd ~/projects/HomoPan_ancestor
```

Crear directorios:

```bash
mkdir -p scripts logs qc targets test_genomes results/test results/full results/ancestors results/regions results/reports
```

Crear metadata:

```bash
cat > accessions.tsv << 'EOF'
homo_sapiens GCA_009914755.4
pan_paniscus GCF_029289425.2
pan_troglodytes GCF_028858775.2
gorilla_gorilla_gorilla GCF_029281585.2
pongo_abelii GCF_028885655.2
EOF
```

---

## 24. Verificación manual antes de correr

```bash
ls -lh genomes/homo_sapiens.fa
ls -lh genomes/pan_paniscus.fa
ls -lh genomes/pan_troglodytes.fa
ls -lh genomes/gorilla_gorilla_gorilla.fa
ls -lh genomes/pongo_abelii.fa
```

Si alguno falta, detener.

---

## 25. Correr test completo

```bash
cd ~/projects/HomoPan_ancestor
bash scripts/run_all_test.sh
```

El test completo debe generar:

```bash
results/test/primates.test.hal
results/ancestors/Anc_HomoPan.test.fa
qc/test_halValidate.txt
qc/test_halStats.txt
qc/test_halTree.txt
qc/test_halGenomes.txt
results/reports/HomoPan_ancestor_report.md
```

---

## 26. Validar test

Revisar:

```bash
halStats --genomes results/test/primates.test.hal
halStats --tree results/test/primates.test.hal
ls -lh results/ancestors/Anc_HomoPan.test.fa
```

Debe aparecer:

```text
Anc_HomoPan
```

---

## 27. Interpretación si solo pasó el test

Usar esta respuesta:

```text
El harness y Cactus funcionan técnicamente. El test de 1 Mb generó un HAL válido, el nodo Anc_HomoPan está presente y la secuencia ancestral pudo extraerse. Sin embargo, este resultado todavía no debe interpretarse biológicamente porque el test usa el primer contig de cada especie y esas regiones no necesariamente son ortólogas. El siguiente paso es correr el pipeline con los genomas completos o con regiones ortólogas confirmadas.
```

---

## 28. Correr full

```bash
cd ~/projects/HomoPan_ancestor
bash scripts/run_all_full.sh
```

O en SLURM:

```bash
sbatch scripts/06_run_full_cactus_slurm.sh
```

---

## 29. Validar full

Revisar:

```bash
halValidate results/full/primates.full.hal
halStats results/full/primates.full.hal
halStats --tree results/full/primates.full.hal
halStats --genomes results/full/primates.full.hal
ls -lh results/ancestors/*.fa
```

Deben existir:

```bash
results/ancestors/Anc_HomoPan.fa
results/ancestors/Pan.fa
results/ancestors/Homininae.fa
results/ancestors/Root.fa
```

---

## 30. Interpretación si pasó el full

Usar esta respuesta:

```text
Sí. La reconstrucción del ancestro Homo–Pan es técnicamente válida porque Cactus terminó correctamente, halValidate pasó, halStats muestra el árbol esperado y los genomas/nodos esperados, y Anc_HomoPan.fa fue extraído exitosamente desde el HAL completo. La interpretación biológica debe hacerse por regiones específicas, considerando calidad de ensamblaje, gaps, repeats y ortología.
```

---

# PARTE C — ARCHIVOS DE SALIDA

---

## 31. Outputs principales

| Archivo | Significado |
|---|---|
| `results/test/primates.test.hal` | HAL del test de 1 Mb |
| `results/full/primates.full.hal` | HAL completo |
| `results/ancestors/Anc_HomoPan.test.fa` | Ancestro Homo–Pan del test |
| `results/ancestors/Anc_HomoPan.fa` | Ancestro Homo–Pan completo |
| `results/ancestors/Pan.fa` | Ancestro Pan |
| `results/ancestors/Homininae.fa` | Ancestro Homininae |
| `results/ancestors/Root.fa` | Root ancestral |
| `results/reports/HomoPan_ancestor_report.md` | Reporte final |

---

## 32. Outputs de QC

| Archivo | Significado |
|---|---|
| `qc/fasta_check.summary.txt` | Resumen de FASTA completos |
| `qc/test_fasta_check.summary.txt` | Resumen de FASTA test |
| `qc/seqfile_check.txt` | Revisión de seqfiles |
| `qc/test_halValidate.txt` | Validación HAL test |
| `qc/test_halStats.txt` | Estadísticas HAL test |
| `qc/test_halTree.txt` | Árbol HAL test |
| `qc/test_halGenomes.txt` | Genomas/nodos HAL test |
| `qc/full_halValidate.txt` | Validación HAL full |
| `qc/full_halStats.txt` | Estadísticas HAL full |
| `qc/full_halTree.txt` | Árbol HAL full |
| `qc/full_halGenomes.txt` | Genomas/nodos HAL full |

---

# PARTE D — ERRORES COMUNES

---

## 33. Error: falta FASTA

Ejemplo:

```text
ERROR: FASTA does not exist: genomes/pan_paniscus.fa
```

Solución:

```bash
ls -lh genomes/
```

Verificar que el nombre sea exacto:

```bash
pan_paniscus.fa
```

No debe ser:

```bash
Pan_paniscus.fa
pan_paniscus.fasta
pan_paniscus.fa.gz
```

Si está comprimido:

```bash
gunzip genomes/pan_paniscus.fa.gz
```

---

## 34. Error: seqfile con columnas incorrectas

Revisar:

```bash
cat -n primates.seqfile
awk 'NR>1{print NF, $1, $2}' primates.seqfile
```

Cada línea después del árbol debe tener exactamente dos columnas:

```text
species_name /absolute/path/to/file.fa
```

Ejemplo correcto:

```text
2 homo_sapiens /home/leandro/projects/HomoPan_ancestor/genomes/homo_sapiens.fa
2 pan_paniscus /home/leandro/projects/HomoPan_ancestor/genomes/pan_paniscus.fa
2 pan_troglodytes /home/leandro/projects/HomoPan_ancestor/genomes/pan_troglodytes.fa
2 gorilla_gorilla_gorilla /home/leandro/projects/HomoPan_ancestor/genomes/gorilla_gorilla_gorilla.fa
2 pongo_abelii /home/leandro/projects/HomoPan_ancestor/genomes/pongo_abelii.fa
```

---

## 35. Error: Anc_HomoPan no aparece

Revisar:

```bash
head -n 1 primates.seqfile
halStats --genomes results/test/primates.test.hal
halStats --tree results/test/primates.test.hal
```

El árbol debe contener exactamente:

```text
Anc_HomoPan
```

---

## 36. Error: jobStore viejo

Si Cactus se queja por un jobStore previo:

```bash
rm -rf js-test
rm -rf js-full
```

Luego repetir.

---

## 37. Error: HAL vacío o no creado

Buscar errores:

```bash
grep -i "error\|failed\|exception" logs/04_run_test_cactus.log
grep -i "error\|failed\|exception" logs/06_run_full_cactus.log
```

Posibles causas:

1. Memoria insuficiente.
2. FASTA corrupto.
3. Seqfile mal formateado.
4. Ruta incorrecta.
5. Cactus no está instalado correctamente.

---

# PARTE E — TARGETS BIOLÓGICOS OPCIONALES

---

## 38. Crear archivo de regiones target

Crear:

```bash
cat > targets/human_targets.bed << 'EOF'
chr12	113344000	113370000	OAS1_OAS2_OAS3
chr11	117850000	118100000	IL10RA_region
chr3	45800000	45950000	CCR_chr3p21_region
EOF
```

Estas regiones son ejemplos. El harness futuro puede usarlas para exportar alineamientos regionales o secuencias comparables.

---

## 39. Advertencia sobre targets

No asumir que una coordenada humana se puede aplicar directamente a todos los genomas sin conversión o mapeo.

Para interpretación biológica se requiere:

1. Confirmar ortología.
2. Revisar gaps.
3. Revisar repeats.
4. Revisar orientación.
5. Revisar calidad del alineamiento.
6. Confirmar que la región ancestral corresponde al locus esperado.

---

# PARTE F — INSTRUCCIÓN FINAL PARA UNA IA/AGENTE

---

## 40. Prompt para el agente que creará el harness

Usar este prompt:

```text
Crea un harness bash reproducible para el proyecto ~/projects/HomoPan_ancestor.

El harness debe usar solo cinco especies:
1. homo_sapiens
2. pan_paniscus
3. pan_troglodytes
4. gorilla_gorilla_gorilla
5. pongo_abelii

No debe usar macaca.

El árbol obligatorio es:
(((homo_sapiens,(pan_paniscus,pan_troglodytes)Pan)Anc_HomoPan,gorilla_gorilla_gorilla)Homininae,pongo_abelii)Root;

El nodo principal de interés es:
Anc_HomoPan

El harness debe crear scripts separados para:
1. revisar ambiente
2. validar FASTA
3. crear FASTA test de 1 Mb
4. crear seqfiles
5. correr Cactus test
6. validar HAL test
7. correr Cactus full
8. validar HAL full
9. extraer ancestros
10. crear reporte
11. hacer resumen QC
12. correr todo el test
13. correr todo el full

Cada script debe usar:
set -euo pipefail

Cada script debe:
- escribir logs
- fallar si faltan archivos
- validar outputs
- imprimir mensajes claros
- no adivinar silenciosamente

Los outputs deben ir en:
results/
qc/
logs/

El reporte final debe explicar si la reconstrucción es técnicamente válida.

El reporte siempre debe advertir que el test de 1 Mb es solo técnico y no debe interpretarse biológicamente si las regiones no son ortólogas.
```

---

# 41. Checklist final de éxito

El pipeline test fue exitoso si existen:

```bash
results/test/primates.test.hal
results/ancestors/Anc_HomoPan.test.fa
qc/test_halValidate.txt
qc/test_halStats.txt
qc/test_halTree.txt
qc/test_halGenomes.txt
```

El pipeline full fue exitoso si existen:

```bash
results/full/primates.full.hal
results/ancestors/Anc_HomoPan.fa
results/ancestors/Pan.fa
results/ancestors/Homininae.fa
results/ancestors/Root.fa
results/reports/HomoPan_ancestor_report.md
```

Y si esto pasa:

```bash
halValidate results/full/primates.full.hal
```

---

# 42. Conclusión

Este README define un pipeline completo y un harness reproducible para reconstruir y validar técnicamente el ancestro **Homo–Pan** usando Cactus/HAL.

El test de 1 Mb responde:

```text
¿Funciona técnicamente el pipeline?
```

El full HAL responde:

```text
¿Se puede obtener una reconstrucción ancestral completa técnicamente válida?
```

El archivo clave final es:

```bash
results/ancestors/Anc_HomoPan.fa
```
