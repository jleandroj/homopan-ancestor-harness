#!/usr/bin/env python3
"""cgv_dotplot.py -- CGV-style synteny plots from normalized blocks.

Reads an all_blocks.tsv with columns:
  aligner human_chr h_start h_end bonobo_chr b_start b_end strand identity_pct
Draws each alignment block as a diagonal segment (human X, bonobo Y), coloured
by orientation: forward (+) blue, reverse (-) red -- the "show both forward and
reverse alignments" view CGV renders. One panel per source (ncbi truth +
each aligner). Reverse blocks are drawn as anti-diagonals so inversions show as
the mirror diagonal, exactly like the CGV figure.

Usage:
  cgv_dotplot.py --blocks all_blocks.tsv --out fig.png --mode test \
                 [--human-chr NC_060925.1 --bonobo-chr NC_073249.2]
"""
import argparse, csv, sys
from collections import defaultdict, OrderedDict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection

FWD_COLOR = "#1f4ed8"   # blue
REV_COLOR = "#d81f2a"   # red
SOURCE_ORDER = ["ncbi", "minimap2", "lastz", "mashmap"]
SOURCE_TITLE = {"ncbi": "NCBI CGV (ground truth)", "minimap2": "minimap2 (asm20)",
                "lastz": "LASTZ", "mashmap": "MashMap"}


def load(path):
    rows = defaultdict(list)
    with open(path) as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            p = line.rstrip("\n").split("\t")
            if len(p) < 8:
                continue
            src, hc, hs, he, bc, bs, be, st = p[0], p[1], int(p[2]), int(p[3]), p[4], int(p[5]), int(p[6]), p[7]
            rows[src].append((hc, hs, he, bc, bs, be, st))
    return rows


def panel(ax, blocks, title, human_chr=None, bonobo_chr=None):
    fwd, rev = [], []
    n = 0
    for hc, hs, he, bc, bs, be, st in blocks:
        if human_chr and hc != human_chr:
            continue
        if bonobo_chr and bc != bonobo_chr:
            continue
        n += 1
        if st == "-":
            rev.append([(hs, be), (he, bs)])   # anti-diagonal for inversions
        else:
            fwd.append([(hs, bs), (he, be)])
    if fwd:
        ax.add_collection(LineCollection(fwd, colors=FWD_COLOR, linewidths=0.6))
    if rev:
        ax.add_collection(LineCollection(rev, colors=REV_COLOR, linewidths=0.6))
    ax.set_title(f"{title}\n{n} blocks  ({len(fwd)}+ / {len(rev)}-)", fontsize=9)
    ax.autoscale()
    ax.ticklabel_format(style="sci", axis="both", scilimits=(6, 6))
    ax.tick_params(labelsize=7)
    return n


def cumulative_offsets(rows, axis):
    """Genome-wide (full mode): assign each contig a cumulative offset, ordered
    by first appearance across all sources, so every panel shares one layout."""
    idx = 0 if axis == "human" else 3
    start_idx = 1 if axis == "human" else 4
    end_idx = 2 if axis == "human" else 5
    maxlen = OrderedDict()
    for src, blks in rows.items():
        for b in blks:
            c = b[idx]; e = b[end_idx]
            if c not in maxlen or e > maxlen[c]:
                maxlen[c] = max(e, maxlen.get(c, 0))
    off, cum = OrderedDict(), 0
    for c, ln in maxlen.items():
        off[c] = cum
        cum += ln
    return off, cum


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--blocks", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--mode", default="test")
    ap.add_argument("--human-chr", default=None)
    ap.add_argument("--bonobo-chr", default=None)
    args = ap.parse_args()

    rows = load(args.blocks)
    sources = [s for s in SOURCE_ORDER if s in rows and rows[s]]
    if not sources:
        sys.exit("cgv_dotplot: no sources with blocks in %s" % args.blocks)

    ncol = 2
    nrow = (len(sources) + 1) // 2
    fig, axes = plt.subplots(nrow, ncol, figsize=(11, 5 * nrow), squeeze=False)

    if args.mode == "full":
        hoff, hmax = cumulative_offsets(rows, "human")
        boff, bmax = cumulative_offsets(rows, "bonobo")

    for i, src in enumerate(sources):
        ax = axes[i // ncol][i % ncol]
        if args.mode == "full":
            shifted = [(b[0], b[1] + hoff[b[0]], b[2] + hoff[b[0]],
                        b[3], b[4] + boff[b[3]], b[5] + boff[b[3]], b[6]) for b in rows[src]]
            panel(ax, shifted, SOURCE_TITLE.get(src, src))
            ax.set_xlim(0, hmax); ax.set_ylim(0, bmax)
            ax.set_xlabel("Human genome (concatenated, bp)", fontsize=8)
            ax.set_ylabel("Bonobo genome (concatenated, bp)", fontsize=8)
        else:
            panel(ax, rows[src], SOURCE_TITLE.get(src, src), args.human_chr, args.bonobo_chr)
            ax.set_xlabel(f"Human {args.human_chr or ''} (bp)", fontsize=8)
            ax.set_ylabel(f"Bonobo {args.bonobo_chr or ''} (bp)", fontsize=8)

    # hide any unused panel
    for j in range(len(sources), nrow * ncol):
        axes[j // ncol][j % ncol].axis("off")

    # shared legend
    from matplotlib.lines import Line2D
    fig.legend([Line2D([0], [0], color=FWD_COLOR, lw=2),
                Line2D([0], [0], color=REV_COLOR, lw=2)],
               ["forward (+)", "reverse (-)"], loc="upper right", fontsize=9)
    title_pair = "" if args.mode == "full" else f"  {args.human_chr} x {args.bonobo_chr}"
    fig.suptitle(f"CGV replication -- Homo sapiens x Pan paniscus ({args.mode}){title_pair}", fontsize=12)
    fig.tight_layout(rect=[0, 0, 1, 0.97])
    fig.savefig(args.out, dpi=130)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
