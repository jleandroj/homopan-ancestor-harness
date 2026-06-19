# Security model — what is and isn't a boundary

This harness has layered controls. Be precise about which are real boundaries
and which are defense-in-depth, so "secure/prod" claims stay honest.

## Layers (strongest → weakest)

1. **OS sandbox — the real boundary.** `scripts/sandbox_run.sh` runs a command
   under **bubblewrap** with a private network namespace (`--unshare-net`, **no
   egress** by default) and a read-only root with only the project + work dir
   writable. This is the only layer that actually *contains* a hostile process.
   - Enable network deliberately: `HOMOPAN_ALLOW_NET=1`.
   - Refuse to run unsandboxed: `HOMOPAN_REQUIRE_SANDBOX=1`.
   - True per-host egress allowlisting needs root/iptables or a filtering proxy
     (not available here without sudo). When network IS shared, the tool-level
     wrappers in `scripts/net_wrappers/` (prepend to `PATH`) enforce
     `egress_allowlist.txt` for `curl`/`wget` — defense-in-depth, **not** a
     kernel boundary (a determined process can bypass a PATH shim).

2. **PreToolUse gate (`.claude/gate_check.sh`) — defense-in-depth, fail-closed.**
   - Content hash of the contract surface **+ the `skills/` tree**: any change
     invalidates the gate pass until `bash init.sh` re-runs.
   - Hardline-denies Write/Edit/NotebookEdit to contract files; denies Bash
     redirects/`tee`/`cp`/`sed -i`/interpreter-writes into them and any
     `.gate_pass` reference; denies `base64|sh`, `curl|sh`, and non-conda
     `eval`; denies `WebFetch`/`WebSearch`.
   - `trap ... exit 2 ERR` → any internal error denies (no fail-open).
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
  size-rotated with `BITACORA_KEEP` generations.

## TL;DR

If you need to run untrusted code or guarantee no egress, wrap it in
`scripts/sandbox_run.sh`. Everything else raises the cost of a mistake but is
not, by itself, a containment boundary.
