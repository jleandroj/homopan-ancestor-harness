#!/usr/bin/env python3
"""
Preflight validation for a Progressive Cactus run.

Validates the inputs that, if wrong, waste hours of compute:
  - Newick tree parses, is rooted, leaf names are clean and unique
  - every genome FASTA in the seqFile exists and is readable
  - tree leaves == seqFile genome names (exact match)
  - softmasking estimate (lowercase fraction) per genome
  - basic assembly stats (#seqs, total length, N50, %N)

Usage:
    python preflight.py --seqfile path/to/seqFile
    python preflight.py --tree "(...);" --genomes name=path name=path ...

Exit code 0 = safe to run. Non-zero = do NOT submit the job; fix the reported issue.
This script never modifies any input file.
"""
import argparse
import gzip
import os
import re
import sys

NAME_RE = re.compile(r"^[A-Za-z0-9_]+$")
MASK_WARN_FRACTION = 0.20   # below this, masking is probably missing for large genomes
N_FRACTION_FLAG = 0.50      # >50% N looks broken


def open_maybe_gzip(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path, "rt")


def parse_seqfile(path):
    with open(path) as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    if not lines:
        sys.exit("ERROR: seqFile is empty")
    tree = lines[0].strip()
    genomes = {}
    for ln in lines[1:]:
        parts = ln.split()
        if len(parts) < 2:
            sys.exit(f"ERROR: malformed genome line (need 'name path'): {ln!r}")
        name, gpath = parts[0], parts[1]
        genomes[name] = gpath
    return tree, genomes


def newick_leaves(tree):
    """Lightweight leaf-name extractor; avoids a hard dependency on ete3/dendropy.
    Leaves are tokens that are immediately followed by ':' or ',' or ')' and are
    not preceded by ')'. We approximate by grabbing names that follow '(' or ','."""
    if not tree.endswith(";"):
        return None, "tree does not end in ';'"
    # tokens of the form  (NAME  or  ,NAME  where NAME is up to ':' , ')'
    leaves = re.findall(r"[(,]\s*([A-Za-z0-9_.\-]+)\s*(?=:|,|\))", tree)
    # internal node labels appear right after ')'; exclude those
    internal = set(re.findall(r"\)\s*([A-Za-z0-9_.\-]+)", tree))
    leaves = [l for l in leaves if l not in internal]
    if not leaves:
        return None, "could not extract any leaf names from tree"
    return leaves, None


def check_tree(tree):
    issues = []
    if tree.count("(") != tree.count(")"):
        issues.append("unbalanced parentheses in Newick tree")
    if not tree.endswith(";"):
        issues.append("tree must terminate with ';'")
    leaves, err = newick_leaves(tree)
    if err:
        issues.append(err)
        return None, issues
    dupes = {x for x in leaves if leaves.count(x) > 1}
    if dupes:
        issues.append(f"duplicate leaf names: {sorted(dupes)}")
    bad = [x for x in leaves if not NAME_RE.match(x)]
    if bad:
        issues.append(f"leaf names with illegal characters (use [A-Za-z0-9_]): {bad}")
    return leaves, issues


def fasta_stats(path):
    """Return dict with nseqs, total_len, n50, masked_frac, n_frac. Streams the file."""
    if not os.path.exists(path):
        return {"error": "file not found"}
    if not os.access(path, os.R_OK):
        return {"error": "not readable"}
    lengths = []
    cur = 0
    total = lower = ncount = 0
    try:
        with open_maybe_gzip(path) as fh:
            first = fh.read(1)
            if first != ">":
                return {"error": "does not start with '>' (not FASTA?)"}
            fh.seek(0)
            for line in fh:
                if line.startswith(">"):
                    if cur:
                        lengths.append(cur)
                    cur = 0
                    continue
                s = line.strip()
                cur += len(s)
                total += len(s)
                lower += sum(1 for c in s if c.islower())
                ncount += s.upper().count("N")
            if cur:
                lengths.append(cur)
    except Exception as e:  # noqa: BLE001
        return {"error": f"read failed: {e}"}
    if total == 0:
        return {"error": "no sequence found"}
    lengths.sort(reverse=True)
    half = total / 2
    run = 0
    n50 = 0
    for L in lengths:
        run += L
        if run >= half:
            n50 = L
            break
    return {
        "nseqs": len(lengths),
        "total_len": total,
        "n50": n50,
        "masked_frac": lower / total,
        "n_frac": ncount / total,
    }


def human(n):
    for unit in ["bp", "kb", "Mb", "Gb"]:
        if n < 1000:
            return f"{n:.1f}{unit}" if unit != "bp" else f"{int(n)}{unit}"
        n /= 1000
    return f"{n:.1f}Tb"


def main():
    ap = argparse.ArgumentParser(description="Cactus preflight validator")
    ap.add_argument("--seqfile", help="Cactus seqFile (tree on line 1, then name path)")
    ap.add_argument("--tree", help="Newick tree string (if not using --seqfile)")
    ap.add_argument("--genomes", nargs="*", default=[],
                    help="name=path entries (if not using --seqfile)")
    args = ap.parse_args()

    if args.seqfile:
        tree, genomes = parse_seqfile(args.seqfile)
    elif args.tree and args.genomes:
        tree = args.tree.strip()
        genomes = {}
        for g in args.genomes:
            if "=" not in g:
                sys.exit(f"ERROR: --genomes entries must be name=path, got {g!r}")
            k, v = g.split("=", 1)
            genomes[k] = v
    else:
        sys.exit("ERROR: provide --seqfile, or both --tree and --genomes")

    fatal = []
    warn = []

    print("=" * 60)
    print("CACTUS PREFLIGHT")
    print("=" * 60)

    # --- tree ---
    leaves, tissues = check_tree(tree)
    print(f"\n[TREE] {len(leaves) if leaves else 0} leaves detected")
    for i in tissues:
        print(f"   FATAL: {i}")
        fatal.append(f"tree: {i}")

    # --- name matching ---
    if leaves is not None:
        leafset, genset = set(leaves), set(genomes)
        only_tree = leafset - genset
        only_seq = genset - leafset
        if only_tree:
            fatal.append(f"tree leaves missing from seqFile: {sorted(only_tree)}")
            print(f"   FATAL: leaves not in seqFile genomes: {sorted(only_tree)}")
        if only_seq:
            fatal.append(f"seqFile genomes missing from tree: {sorted(only_seq)}")
            print(f"   FATAL: genomes not in tree: {sorted(only_seq)}")
        if not only_tree and not only_seq:
            print("   OK: tree leaves and seqFile genome names match exactly")

    # --- genomes ---
    print(f"\n[GENOMES] {len(genomes)} entries")
    for name, gpath in genomes.items():
        st = fasta_stats(gpath)
        if "error" in st:
            print(f"   FATAL  {name}: {st['error']}  ({gpath})")
            fatal.append(f"{name}: {st['error']}")
            continue
        flags = []
        if st["masked_frac"] < MASK_WARN_FRACTION:
            flags.append(f"LOW MASKING {st['masked_frac']*100:.1f}% (softmask first?)")
            warn.append(f"{name}: low softmasking ({st['masked_frac']*100:.1f}%)")
        if st["n_frac"] > N_FRACTION_FLAG:
            flags.append(f"HIGH N {st['n_frac']*100:.1f}%")
            warn.append(f"{name}: {st['n_frac']*100:.1f}% Ns")
        flagstr = ("  <-- " + "; ".join(flags)) if flags else ""
        print(f"   {name:>14}: {st['nseqs']} seqs, {human(st['total_len'])}, "
              f"N50 {human(st['n50'])}, masked {st['masked_frac']*100:.1f}%, "
              f"N {st['n_frac']*100:.1f}%{flagstr}")

    # --- verdict ---
    print("\n" + "=" * 60)
    if fatal:
        print("RESULT: NOT SAFE TO RUN. Fix these first:")
        for f in fatal:
            print(f"  - {f}")
        if warn:
            print("Warnings:")
            for w in warn:
                print(f"  - {w}")
        sys.exit(2)
    if warn:
        print("RESULT: RUNNABLE, but review warnings:")
        for w in warn:
            print(f"  - {w}")
        print("(low masking will sharply increase runtime; softmask in Step 1.)")
        sys.exit(0)
    print("RESULT: All checks passed. Safe to build the seqFile and submit.")
    sys.exit(0)


if __name__ == "__main__":
    main()
