# Security model — what is and isn't a boundary

This harness has layered controls. Be precise about which are real boundaries
and which are defense-in-depth, so "secure/prod" claims stay honest.

## Layers (strongest → weakest)

1. **OS sandbox — the real boundary.** `scripts/sandbox_run.sh` runs a command
   under **bubblewrap** with a private network namespace (`--unshare-net`, **no
   egress** by default) and a read-only root with only the project + work dir
   writable. This is the only layer that actually *contains* a hostile process.
   - **Fail-closed by default:** if `bwrap` is missing it refuses to run; set
     `HOMOPAN_ALLOW_UNSANDBOXED=1` to override.
   - Enable network deliberately: `HOMOPAN_ALLOW_NET=1`.
   - Route the Cactus/HAL compute through the sandbox (EXPERIMENTAL):
     `HOMOPAN_SANDBOX_COMPUTE=1` (nested apptainer-in-bwrap may need host
     userns config; off by default so the pipeline isn't broken).
   - Tighten the apptainer container itself (opt-in):
     `HOMOPAN_APPTAINER_ISOLATE=1` adds `--containall --no-home --cleanenv`;
     `HOMOPAN_APPTAINER_NONET=1` adds `--net --network none`. Off by default
     (these need host support and can break some apptainer setups).
   - True per-host egress allowlisting needs root/iptables or a filtering proxy
     (not available here without sudo). When network IS shared, the tool-level
     wrappers in `scripts/net_wrappers/` (prepend to `PATH`) enforce
     `egress_allowlist.txt` for `curl`/`wget` — defense-in-depth, **not** a
     kernel boundary (a determined process can bypass a PATH shim).

2. **PreToolUse gate (`.claude/gate_check.sh`) — an ANTI-ACCIDENT guardrail,
   fail-closed.** Its job is to stop a *well-intentioned mistake* (an agent
   about to clobber a contract file, fetch-and-run, or touch clinical data),
   NOT to contain a hostile process — that is layer 1's job.
   - Content hash of the contract surface **+ the `skills/` tree + the boundary
     scripts** (`sandbox_run.sh`, `net_wrappers/`, `egress_allowlist.txt`): any
     change invalidates the gate pass until `bash init.sh` re-runs.
   - The dangerous-command heuristics live in a standalone, fuzzed module
     (`.claude/cmd_detector.sh`, tested by `tests/test_cmd_detector_fuzz.sh`)
     that `gate_check.sh` sources — so the parser can be exercised in isolation.
   - Hardline-denies Write/Edit/NotebookEdit to contract files; denies Bash
     redirects/`tee`/`cp`/`sed -i`/interpreter-writes into them and any
     `.gate_pass` reference; denies `base64|sh`, `curl|sh`, and non-conda
     `eval`; denies `WebFetch`/`WebSearch`.
   - **Exit-code contract:** the gate emits **only 0 (allow) or 2 (deny)** —
     never any other code. This matters because Claude Code treats *only* exit 2
     as blocking; any other non-zero fail-OPENs. `trap ... exit 2 ERR` forces a
     deny on any internal error, and `tests/test_gate_exitcode.sh` asserts the
     exact `rc==2` across an adversarial matrix so a regression can't silently
     fail-open.
   - **Not a boundary:** command parsing is heuristic. Obfuscation it doesn't
     recognize can slip through; the hash backstop only *detects after the
     fact*. Treat it as guardrails, not a jail. Use layer 1 for untrusted code.

3. **Native `permissions.deny` (`.claude/settings.json`) — advisory.**
   Denies clinical `il10_analisis/**`, contract files, egress tools. Useful and
   native, but **globs are not a security frontier** (path normalization,
   symlinks, new tool names can evade). Belt-and-suspenders with layers 1–2.

## Requirements / decisions

- **jq is required.** The gate parses hook JSON with it and fail-closes if
  absent; `init.sh` now *fails* (not warns) when jq is unresolvable, so a green
  init guarantees the gate can run.
- **PreToolUse matcher is `*`** (default-deny posture): the gate sees every
  tool and only explicitly allow-lists read-only ones. An explicit
  `Write|Edit|...` matcher would silently miss any future mutating tool, so `*`
  is intentional.
- **Logs** (`logs/bitacora.jsonl`): mutating tools only, secrets redacted,
  size-rotated with `BITACORA_KEEP` generations; mirrored to an external
  append-only audit log (`HOMOPAN_AUDIT_LOG`, default `~/.homopan_audit.jsonl`).
  Each line carries `run_id`/`agent`/`session` for attribution across
  concurrent or resumed runs.
  - **Make the external log tamper-evident:** `sudo chattr +a ~/.homopan_audit.jsonl`
    so history can only be appended, never rewritten in place (needs ext4/xfs +
    `CAP_LINUX_IMMUTABLE`). Verify integrity + local↔external consistency with
    `bash scripts/audit_verify.sh` (checks every in-repo line is present in the
    external superset and reports drift / missing append-only flag).
- **Sandboxed compute is opt-OUT** (`HOMOPAN_SANDBOX_COMPUTE`, default `auto`):
  the pipeline routes Cactus through `sandbox_run.sh` by default, but PROBES
  whether the host can nest the sandbox (unprivileged userns) and, if not, warns
  and falls back to direct compute so runs still complete. Force with `=1`,
  disable with `=0`.
- **Fingerprint blind spot (idempotency, not security):** large-file
  fingerprints (genomes, HAL) hash size+mtime+the first & last 1 MiB, NOT the
  whole file — chosen so a multi-GB check costs ~2 MiB of reads. A crafted edit
  in the *interior* of a large file that preserves size and mtime would NOT be
  detected by the marker. This is acceptable because the markers are an
  idempotency control (catch accidental input/output drift & truncation), not a
  tamper-defense; integrity of untrusted artifacts is layer 1's job, and HAL
  outputs additionally pass `halValidate` before a step is marked done.
- **Sandbox requires unprivileged user namespaces.** bubblewrap runs rootless
  via user namespaces, so the host needs `kernel.unprivileged_userns_clone=1`
  (Debian/Ubuntu) / a non-zero `user.max_user_namespaces`. Without it `bwrap`
  fails and the sandbox is fail-closed (set `HOMOPAN_ALLOW_UNSANDBOXED=1` only
  if you accept running without isolation).

## TL;DR

If you need to run untrusted code or guarantee no egress, wrap it in
`scripts/sandbox_run.sh`. Everything else raises the cost of a mistake but is
not, by itself, a containment boundary.
