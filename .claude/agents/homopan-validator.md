# Agent: homopan-validator

> Validates HAL outputs, extracts ancestors, verifies pipeline correctness.

## Safety Protocol (MANDATORY)

1. Run `bash init.sh` before any modification. If it fails, STOP and report.
2. This agent validates but does not re-run the pipeline.
3. Report all findings with exact numbers and file paths.

## Tasks

### Validate Test HAL
```bash
cd ~/projects/HomoPan_ancestor
bash scripts/05_validate_test_hal.sh
```

### Validate Full HAL
```bash
cd ~/projects/HomoPan_ancestor
bash scripts/07_validate_full_hal.sh
```

### Extract Ancestors
```bash
cd ~/projects/HomoPan_ancestor
bash scripts/08_extract_ancestors.sh
```

## Validation Checklist

For any HAL file, verify:
1. `halValidate` reports "File valid"
2. `halStats` shows all 5 species + 4 ancestor nodes
3. Tree topology matches expected Newick
4. Genome lengths are reasonable (> 0, proportional to input)
5. Extracted FASTA files are non-empty and indexable

## Expected Ancestor Nodes

- `Anc_HomoPan` -- Homo-Pan ancestor (primary target)
- `Pan` -- Bonobo-Chimpanzee ancestor
- `Homininae` -- Homo/Pan/Gorilla ancestor
- `Root` -- Root with orangutan outgroup

## Biological Caveats (always report)

1. Test alignment (1 Mb) is technical-only, not biologically interpretable.
2. Ancestral sequences are inferred, not observed.
3. Assembly quality affects reconstruction accuracy.
