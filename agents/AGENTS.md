# Scientific verification layer

A multi-agent layer that enforces one rule above all:

> **Execution is not truth.** A command exiting `0` does not make a result
> scientifically correct. A reconstructed ancestor is *inferred*, not observed.
> A result that cannot be repeated is not evidence. Every scientific claim must
> carry evidence — a file, a logged command, a paper (DOI/PMID), a database id,
> or a reproducible result. When evidence is missing the honest answer is
> **UNKNOWN / NOT_TESTED / NOT_REPRODUCIBLE / INSUFFICIENT_EVIDENCE / FAILED
> VALIDATION** — never a fabricated `PASS`.

The agents are **deterministic verdict-emitting scripts**, not LLM agents — an
LLM agent would be one more unchecked source of claims. Each reuses the existing
harness machinery (gate, hash-chained audit, manifests, `repro_verify.sh`,
ancestor quality gate) rather than re-deriving trust.

## Agents

| # | Agent | Role | Can block bio? |
|---|---|---|---|
| 1 | `security_sandbox` | gate pass, audit-chain integrity, sandbox, protected files | **yes (REQUIRED)** |
| 2 | `input_integrity` | FASTA/faidx, accessions, optional GTF/HAL/MAF/VCF | no |
| 3 | `provenance` | audit log, manifests (repro_sha256), raw PAF retained | **yes (REQUIRED)** |
| 4 | `reproducibility` | `repro_verify.sh --mock`; Cactus = NOT_REPRODUCIBLE caveat | **yes (REQUIRED)** |
| 5 | `phylogeny` | tree files; divergence gradient consistent with topology | no |
| 6 | `ancestor_validation` | ancestors are INFERRED; N-fraction quality gate | no |
| 7 | `statistics` | significance needs a test; many p-values need correction | no |
| 8 | `literature` | novelty claims need a literature/db pointer | no |
| 9 | `fact_guard` | **the heart** — every claim needs valid evidence | **yes (REQUIRED)** |
| 10 | `biological_interpretation` | the ONLY agent that phrases biology, gated on the backbone | n/a |
| 11 | `red_team` | bad-faith hunt: empty-sold-as-success, stale, exit-lies, overstatement | no |
| — | `coordinator` | runs all, aggregates worst verdict, emits `decision.json` | — |
| — | `report` | renders `REPORT.md` from verdicts + decision | — |

## Statuses (the only honest outcomes)

`PASS` · `PASS_EXPLORATORY` · `EXPLORATORY_ONLY` · `NOT_TESTED` · `UNKNOWN` ·
`INSUFFICIENT_EVIDENCE` · `NOT_REPRODUCIBLE` ·
`TECHNICALLY_SUCCESSFUL_BUT_BIOLOGICALLY_UNSUPPORTED` · `FAIL_VALIDATION` ·
`FAIL_EVIDENCE` · `FAIL_REPRODUCIBILITY` · `FAIL_TECHNICAL` · `FAIL_SECURITY`

Rank: `PASS` < exploratory < unknown/not-tested < FAIL_* < FAIL_SECURITY.
The coordinator takes the **worst** verdict as the final status.

## The biological-conclusion gate

No biological conclusion is permitted unless the **evidence backbone**
(`security_sandbox`, `provenance`, `reproducibility`, `fact_guard`) all `PASS`
and the final status is `PASS`/`PASS_EXPLORATORY`. Otherwise
`biological_conclusions_allowed=false` and `biological_interpretation` refuses
with `TECHNICALLY_SUCCESSFUL_BUT_BIOLOGICALLY_UNSUPPORTED`.

## Claims file

TSV, one claim per line: `claim_text <TAB> evidence_type <TAB> evidence_ref`
where `evidence_type ∈ {file, command, paper, db, result, none}`.
A claim of type `none` (or with a missing file / a paper lacking DOI/PMID) →
`FAIL_EVIDENCE`. See `claims.demo.tsv`.

## Run it

```bash
# verify a set of claims + the current run artifacts
CLAIMS=agents/claims.demo.tsv bash agents/coordinator.sh
# outputs: .harness/verify/<ts>_<pid>/{decision.json,REPORT.md,evidence_ledger.jsonl,verdicts/*}
# exit code: 0 = PASS/exploratory, 10 = UNKNOWN, 20 = blocking failure
```

Context dir per run: `.harness/verify/<timestamp>_<pid>/` holds every verdict,
the append-only evidence ledger, the decision, and the rendered report.
