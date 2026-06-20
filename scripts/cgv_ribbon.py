#!/usr/bin/env python3
"""cgv_ribbon.py -- NCBI-CGV-style linear synteny RIBBON plot.

Two chromosome bars (y1 = bonobo on top, y2 = human on bottom by default);
each alignment block is drawn as a ribbon connecting its human span (one bar)
to its bonobo span (the other), coloured by orientation:
  forward (+) -> green   reverse (-) -> blue
Reverse ribbons cross (h_start->b_end, h_end->b_start) so inversions show as
the twisting/crossing ribbons, exactly as CGV renders them.

Heavily parameterised so many visual variants can be generated and compared.

Input blocks TSV (the cgv normalized schema; default uses the ncbi truth rows):
  aligner human_chr h_start h_end bonobo_chr b_start b_end strand identity_pct
FAI files give chromosome lengths; name maps give accession->label + ordering.
"""
import argparse, sys
from collections import defaultdict, OrderedDict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.path import Path
from matplotlib.patches import PathPatch, Rectangle

# CGV-like palette
GREEN = "#5cb85c"
BLUE  = "#2e3192"


def load_names(path):
    m = OrderedDict()
    if path:
        with open(path) as fh:
            for line in fh:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 2:
                    m[p[0]] = p[1]
    return m


def load_fai(path):
    L = {}
    with open(path) as fh:
        for line in fh:
            p = line.split("\t")
            if len(p) >= 2:
                L[p[0]] = int(p[1])
    return L


def chr_sort_key(name):
    # numeric chromosomes first (1,2,...), then X, Y, then anything else
    try:
        return (0, int(name), name)
    except ValueError:
        order = {"X": 1, "Y": 2, "MT": 3, "M": 3}
        return (1, order.get(name.upper(), 99), name)


def build_layout(accs, names, lengths, gap_frac):
    """Order accessions by chromosome label; assign x offsets with gaps.
    Returns (offset[acc], total_width, ordered[(acc,label,len)])."""
    items = [(a, names.get(a, a), lengths.get(a, 0)) for a in accs if lengths.get(a, 0) > 0]
    items.sort(key=lambda t: chr_sort_key(t[1]))
    total_len = sum(t[2] for t in items)
    gap = total_len * gap_frac
    off, x = {}, 0.0
    for a, lab, ln in items:
        off[a] = x
        x += ln + gap
    return off, (x - gap if items else 1.0), items


def ribbon_path(hx0, hx1, bx0, bx1, y_lo, y_hi, strand, curve):
    """Filled ribbon between bottom span [hx0,hx1]@y_lo and top span on y_hi.
    forward: h0->b0, h1->b1 ; reverse: h0->b1, h1->b0 (crossing)."""
    if strand == "-":
        ta, tb = bx1, bx0          # crossing
    else:
        ta, tb = bx0, bx1
    dy = (y_hi - y_lo)
    c = curve * dy
    verts = [
        (hx0, y_lo),
        (hx0, y_lo + c), (ta, y_hi - c), (ta, y_hi),     # left bezier up
        (tb, y_hi),                                       # across top
        (tb, y_hi - c), (hx1, y_lo + c), (hx1, y_lo),     # right bezier down
        (hx0, y_lo),                                      # close (across bottom)
    ]
    codes = [Path.MOVETO,
             Path.CURVE4, Path.CURVE4, Path.CURVE4,
             Path.LINETO,
             Path.CURVE4, Path.CURVE4, Path.CURVE4,
             Path.CLOSEPOLY]
    return Path(verts, codes)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--blocks", required=True)
    ap.add_argument("--source", default="ncbi", help="aligner column value to plot")
    ap.add_argument("--human-fai", required=True)
    ap.add_argument("--bonobo-fai", required=True)
    ap.add_argument("--human-names", required=True)
    ap.add_argument("--bonobo-names", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--title", default="")
    # style knobs
    ap.add_argument("--min-bp", type=int, default=0, help="skip blocks smaller than this")
    ap.add_argument("--merge-gap", type=int, default=0, help="merge same chr-pair+strand blocks within this gap (0=off)")
    ap.add_argument("--alpha", type=float, default=0.5)
    ap.add_argument("--curve", type=float, default=0.5, help="bezier vertical curvature 0..0.5")
    ap.add_argument("--gap-frac", type=float, default=0.005, help="inter-chromosome gap as frac of genome")
    ap.add_argument("--bar-h", type=float, default=0.06)
    ap.add_argument("--edge", type=float, default=0.0, help="ribbon edge linewidth")
    ap.add_argument("--bonobo-top", action="store_true", default=True)
    ap.add_argument("--human-top", dest="bonobo_top", action="store_false")
    ap.add_argument("--figw", type=float, default=20.0)
    ap.add_argument("--figh", type=float, default=6.0)
    ap.add_argument("--green", default=GREEN)
    ap.add_argument("--blue", default=BLUE)
    args = ap.parse_args()

    hnames, bnames = load_names(args.human_names), load_names(args.bonobo_names)
    hlen, blen = load_fai(args.human_fai), load_fai(args.bonobo_fai)

    blocks = []
    hset, bset = set(), set()
    with open(args.blocks) as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            p = line.rstrip("\n").split("\t")
            if len(p) < 8 or p[0] != args.source:
                continue
            hc, hs, he, bc, bs, be, st = p[1], int(p[2]), int(p[3]), p[4], int(p[5]), int(p[6]), p[7]
            blocks.append([hc, hs, he, bc, bs, be, st])
            hset.add(hc); bset.add(bc)
    if not blocks:
        sys.exit(f"cgv_ribbon: no '{args.source}' blocks in {args.blocks}")

    if args.merge_gap > 0:
        groups = defaultdict(list)
        for hc, hs, he, bc, bs, be, st in blocks:
            groups[(hc, bc, st)].append((hs, he, bs, be))
        merged = []
        for (hc, bc, st), segs in groups.items():
            segs.sort()
            chs, che, cbs, cbe = segs[0]
            for hs, he, bs, be in segs[1:]:
                if hs - che <= args.merge_gap and min(abs(bs - cbe), abs(cbs - be)) <= args.merge_gap:
                    che = max(che, he); cbs = min(cbs, bs); cbe = max(cbe, be)
                else:
                    merged.append([hc, chs, che, bc, cbs, cbe, st]); chs, che, cbs, cbe = hs, he, bs, be
            merged.append([hc, chs, che, bc, cbs, cbe, st])
        blocks = merged

    blocks = [b for b in blocks if (b[2] - b[1]) >= args.min_bp]

    hoff, hwidth, hitems = build_layout(hset, hnames, hlen, args.gap_frac)
    boff, bwidth, bitems = build_layout(bset, bnames, blen, args.gap_frac)
    W = max(hwidth, bwidth)
    # center the shorter genome
    hpad = (W - hwidth) / 2.0
    bpad = (W - bwidth) / 2.0

    fig, ax = plt.subplots(figsize=(args.figw, args.figh))
    bar_h = args.bar_h * W if args.bar_h < 1 else args.bar_h
    Y = 1.0
    y_h = (0.0, args.bar_h)                 # human bar (bottom)
    y_b = (Y, Y + args.bar_h)               # bonobo bar (top)
    # which is top?
    if not args.bonobo_top:
        y_h, y_b = y_b, y_h

    # ribbon vertical span between the inner edges of the two bars
    y_lo = max(y_h) ; y_hi = min(y_b)
    # human is at the bottom bar coords y_h; if human is top, geometry still works
    # because we always draw from human-span to bonobo-span.
    human_y = y_h[1] if y_h[0] < y_b[0] else y_h[0]
    bonobo_y = y_b[0] if y_b[0] > y_h[0] else y_b[1]
    lo, hi = sorted([human_y, bonobo_y])

    for hc, hs, he, bc, bs, be, st in blocks:
        hx0 = hpad + hoff[hc] + hs; hx1 = hpad + hoff[hc] + he
        bx0 = bpad + boff[bc] + bs; bx1 = bpad + boff[bc] + be
        # bottom span must be the human one when human is the lower bar; the path
        # helper draws bottom=[hx0,hx1]@lo, top span@hi. If bonobo is lower, swap.
        col = args.blue if st == "-" else args.green
        if human_y <= bonobo_y:
            pth = ribbon_path(hx0, hx1, bx0, bx1, lo, hi, st, args.curve)
        else:
            pth = ribbon_path(bx0, bx1, hx0, hx1, lo, hi, st, args.curve)
        ax.add_patch(PathPatch(pth, facecolor=col, edgecolor=col if args.edge else "none",
                               lw=args.edge, alpha=args.alpha))

    # chromosome bars + labels
    def draw_bar(items, pad, off, ybar, genome_label):
        for a, lab, ln in items:
            x = pad + off[a]
            ax.add_patch(Rectangle((x, ybar[0]), ln, ybar[1] - ybar[0],
                                   facecolor="#dddddd", edgecolor="#333333", lw=0.6, zorder=5))
            ax.text(x + ln / 2, (ybar[0] + ybar[1]) / 2, lab, ha="center", va="center",
                    fontsize=7, zorder=6)
        ax.text(-0.01 * W, (ybar[0] + ybar[1]) / 2, genome_label, ha="right", va="center",
                fontsize=9, style="italic")

    draw_bar(bitems, bpad, boff, y_b, "Pan paniscus")
    draw_bar(hitems, hpad, hoff, y_h, "Homo sapiens")

    ax.set_xlim(-0.05 * W, W * 1.02)
    ax.set_ylim(min(y_h[0], y_b[0]) - 0.15, max(y_h[1], y_b[1]) + 0.15)
    ax.axis("off")
    from matplotlib.lines import Line2D
    ax.legend([Line2D([0], [0], color=args.green, lw=6), Line2D([0], [0], color=args.blue, lw=6)],
              ["forward (+)", "reverse (-)"], loc="upper right", fontsize=9, frameon=False)
    ax.set_title(args.title or "CGV-style synteny — Homo sapiens × Pan paniscus", fontsize=12)
    fig.tight_layout()
    fig.savefig(args.out, dpi=130)
    print(f"wrote {args.out} ({len(blocks)} ribbons)")


if __name__ == "__main__":
    main()
