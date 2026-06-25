# Anti-Deception Playbook for AI/Agent Harnesses

**Goal:** stop an AI/agent from lying to you — or, where lying cannot be fully
prevented, make every lie *loud* instead of *silent*, and declare exactly where
you can still be fooled. Portable: copy the patterns into any shell-based harness.

> **Guiding principle — EXECUTION IS NOT TRUTH.**
> A command exiting 0 is not a correct result. A figure looking reasonable is not
> a valid inference. A reconstructed/derived artifact is not an observed fact.
> A non-reproducible result is not evidence. The harness must prefer to say
> `UNKNOWN / NOT_TESTED / NOT_REPRODUCIBLE / INSUFFICIENT_EVIDENCE` over guessing.
> Design for **100% operational honesty**, never claim 100% scientific certainty.

---

## 0. Threat model — the 7 ways an AI/agent lies to you

| # | Lie vector | Can a harness catch it? |
|---|---|---|
| 1 | **Fakes a result** (says "reproducible", "passed", "significant") | ✅ if you recompute, not trust |
| 2 | **Prose ≠ files** (states a number in chat that the file contradicts) | ✅ for declared numbers; ⚠️ free prose is irreducible |
| 3 | **Tampers the log** (edits/deletes its own history) | ✅ hash-chain + external anchor |
| 4 | **Treats derived as observed** (inferred ancestor / imputed value as fact) | ✅ a dedicated validator |
| 5 | **Cherry-picks across runs** (runs 20×, shows the 1 that confirms) | ✅ smell-detectable via a ledger |
| 6 | **Unbacked / unsupported claims** (no evidence, or evidence that doesn't support it) | ✅ evidence + semantic check |
| 7 | **Wrong-but-valid config / hidden rationale** (flipped contrast, wrong threshold) | ❌ **irreducible** — needs human review |

The defenses below map 1:1. Each is small, deterministic, and copy-pasteable.

---

## 1. The verdict vocabulary (use this everywhere)

Never let a check return a bare boolean. Every check emits one of:

```
PASS                         proven, evidence-backed, reproducible
PASS_EXPLORATORY             usable but not confirmatory (e.g. inferred/equivalent)
FAIL_TECHNICAL               failed a structural/validation check
FAIL_REPRODUCIBILITY         results diverge across runs
FAIL_EVIDENCE                a claim has no / wrong backing
FAIL_SECURITY                destructive / credential / escape attempt
UNKNOWN                      could not decide
NOT_TESTED                   nothing was checked (be loud about this!)
INSUFFICIENT_EVIDENCE        asserted but not measured
```

Rule: **a check that cannot verify must NOT return PASS.** Silence is `NOT_TESTED`,
not success.

---

## 2. Defense patterns (copy-paste)

### Pattern A — RECOMPUTE, never trust a claimed result  (lie #1, #2)
The agent says "bit-identical / reproducible". Do not believe a flag — recompute.

```bash
# repro_check.sh <artifact_a> <artifact_b>
# exit 0 + PASS only if YOU recomputed identity; a bare assertion is rejected.
a="$1"; b="$2"
[[ -f "$a" && -f "$b" ]] || { echo "INSUFFICIENT_EVIDENCE: no artifacts to recompute"; exit 1; }
sa=$(sha256sum "$a" | cut -d' ' -f1); sb=$(sha256sum "$b" | cut -d' ' -f1)
[[ "$sa" == "$sb" ]] && echo "PASS: bit-identical (agent-recomputed)" \
                     || { echo "FAIL_REPRODUCIBILITY: $sa != $sb"; exit 1; }
```
Key: the harness computes the hashes itself. A `{"bit_identical":true}` with no
artifacts → `INSUFFICIENT_EVIDENCE`, never PASS.

### Pattern B — Reconcile prose against the file  (lie #2)
Any number the AI states is unverified until checked against disk.

```bash
# reconcile.sh <file> <stated_value> [grep_pattern]
file="$1"; stated="$2"; pat="${3:-}"
[[ -n "$pat" ]] && actual=$(grep -Ec -- "$pat" "$file") || actual=$(grep -cvE '^\s*(#|$)' "$file")
[[ "$stated" == "$actual" ]] && echo "MATCH ($actual)" || { echo "MISMATCH stated=$stated actual=$actual"; exit 1; }
```
Usage: AI says "500 significant genes" → `reconcile.sh de.tsv 500 $'\tsig'`.

### Pattern C — Tamper-evident log: hash-chain + external anchor  (lie #3)
Each log line carries `prev = sha256(previous line)`. Editing/deleting any line
breaks the chain. Anchor the final head to an **append-only** external log
(`chattr +a`) so a full-chain recompute is also caught.

```bash
# append a chained event
prev="${PREV:-genesis}"
line=$(jq -cn --arg t "$1" --arg prev "$prev" --arg ts "$(date -u +%FT%TSZ)" \
        '{ts:$ts,type:$t,prev:$prev}')
printf '%s\n' "$line" >> audit.jsonl
PREV=$(printf '%s' "$line" | sha256sum | cut -d' ' -f1)
# at the end: anchor head+count to the EXTERNAL append-only log
echo "{\"type\":\"anchor\",\"run\":\"$RUN\",\"lines\":$N,\"head\":\"$PREV\"}" >> "$EXTERNAL_LOG"

# verify: recompute the chain; if a line's .prev != sha(previous line) -> TAMPER.
# then check the recomputed head/count == the external anchor (defeats recompute).
```
Admin step (closes the recompute hole): `chattr +a "$EXTERNAL_LOG"`.

### Pattern D — Derived ≠ observed  (lie #4)
A dedicated validator that **never** lets an inferred/imputed artifact be reported
as observed. Its best verdict is `PASS_EXPLORATORY`, and it requires a provenance
sidecar marking the artifact as non-deterministic/inferred.

```bash
# for each derived artifact: require <file>.provenance.json with reproducible=false
prov="$fa.provenance.json"
[[ -f "$prov" ]] && [[ "$(jq -r '.determinism.reproducible' < "$prov")" == "false" ]] \
  && echo "PASS_EXPLORATORY: INFERRED, exploratory only (NOT observed)" \
  || echo "INSUFFICIENT_EVIDENCE: cannot confirm it is labelled inferred"
```

### Pattern E — Ledger to expose cherry-picking  (lie #5)
Record EVERY run in an append-only ledger keyed by an `inputs_hash`. Then flag any
input-set that was run more than once — hidden siblings become visible.

```bash
# on every run:
echo "{\"ts\":\"$(date -u +%FT%TSZ)\",\"inputs_hash\":\"$IH\",\"final\":\"$VERDICT\"}" >> runs/_ledger.jsonl
# audit:
jq -rs 'group_by(.inputs_hash)|map(select(length>1))
        |.[]|"CHERRY-PICK SMELL: \(.[0].inputs_hash): \(length) runs"' < runs/_ledger.jsonl
```

### Pattern F — Evidence + semantic check  (lie #6)
Every claim needs a backing reference; if a token is declared, the cited file must
actually CONTAIN it (upgrades "evidence exists" → "evidence supports the claim").

```bash
# claims.tsv:  <claim> \t <evidence_ref> \t [required_token]
while IFS=$'\t' read -r claim ev token; do
  [[ -z "$ev" || "$ev" == none ]] && { echo "FAIL_EVIDENCE: unbacked: $claim"; continue; }
  [[ -f "$ev" && -n "$token" ]] && ! grep -qF -- "$token" "$ev" \
    && echo "FAIL_EVIDENCE: '$token' not in $ev for: $claim"
done < claims.tsv
```

### Pattern G — Sandbox + allowlist + limits  (security, lie #1 side-channel)
Run everything THROUGH the harness: deny-by-default allowlist of programs, per-action
timeout, kill-switch, resource rlimits, and a real sandbox (bubblewrap) fail-closed.
Anything not on the allowlist is refused and logged; if a sandbox is requested but
unavailable, ABORT (never silently run uncontained).

---

## 3. The Coordinator — block conclusions without evidence

One orchestrator runs all checks, collects verdicts, and decides. **The gate:**

```
final = PASS  ONLY IF  evidence-gate=PASS AND provenance-gate=PASS AND reproducibility=PASS
                       AND no FAIL_* anywhere AND nothing is EXPLORATORY/UNKNOWN.
otherwise   -> FAIL_*  (worst dominates: security > reproducibility > evidence > technical)
            -> or PASS_EXPLORATORY (some evidence, not confirmatory)
            -> or UNKNOWN (not enough was tested)
```

Worst-status-wins precedence; a biological/scientific conclusion is **withheld**
unless the mandatory gates pass. This is the firewall that turns "it ran" into a
gated verdict.

---

## 4. Make it automatic (every turn)

Wire a **Stop hook** (fires after each agent turn) that runs the checks fail-open:

```json
// settings.json
"Stop": [ { "matcher": "*", "hooks": [
  { "type": "command", "command": "bash scripts/harness/auto_verify.sh" } ] } ]
```
`auto_verify.sh` runs the ledger/cherry-pick check, the declared-claims check, and
the audit-log integrity check, then prints `🔎 AUTO-VERIFY: ...`. It **never blocks**
(exit 0). Now the user audits nothing by hand — the harness self-audits each turn.

Convention to auto-cover prose (#2): the agent writes every quantitative claim to
`claims.tsv` (`claim ⇥ file ⇥ token`); the hook reconciles them automatically.

---

## 5. The irreducible limits — DECLARE them in every report

No harness closes these; say so out loud so the human stays responsible:

1. **Wrong-but-valid config** (flipped numerator/denominator, wrong FDR, wrong id
   type) → a *valid* result that passes every check but is scientifically false.
   **Needs human design review.**
2. **AI rationale** (why this config) → recorded as available, never replayable.
3. **Free chat prose you never declared** → cannot be auto-extracted reliably.

Put a fixed block at the bottom of every generated report:
> *This verdict covers structure, evidence-linkage, reproducibility and log
> integrity. It does NOT cover scientific intent (wrong-but-valid config), the
> agent's rationale, or undeclared chat prose. Trust the verdict table, not the
> sentences. Reconcile any stated number against its file.*

---

## 6. Adoption checklist (step by step, in order)

1. **Adopt the vocabulary** (§1). Forbid bare booleans; default to `NOT_TESTED`.
2. **Single execution path** — every action goes through one `exec` wrapper that
   captures cmd + stdin-hash + stdout + stderr + duration + exit (§2G).
3. **Tamper-evident log** (Pattern C) + `chattr +a` the external anchor.
4. **Recompute, don't trust** (Pattern A) for every "it passed / it matches" claim.
5. **Evidence + semantic check** (Pattern F): require `claims.tsv`; no claim → no
   conclusion.
6. **Derived-not-observed validator** (Pattern D) for every inferred artifact.
7. **Ledger** (Pattern E) for cross-run cherry-pick visibility.
8. **Coordinator gating** (§3): conclusions blocked unless mandatory gates pass.
9. **Reconcile tool** (Pattern B) for prose-vs-file, wired into the Stop hook (§4).
10. **Auto-verify Stop hook** (§4) so it runs every turn, fail-open.
11. **Declare the irreducible limits** (§5) in every report.
12. **Test adversarially**: feed each lie (#1–#6) and assert the harness catches it
    (a passing test suite that *tries to lie* is the only proof the defenses work).

> Done right, the guarantee is not "the AI cannot lie." It is:
> **"the AI cannot lie in silence about anything verifiable, and the harness tells
> you exactly where it still could." Its failure mode is caution (UNKNOWN), never
> false confidence.**
