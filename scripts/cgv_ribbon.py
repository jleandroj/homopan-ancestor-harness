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


def parse_blocks(path, source, named_only, hnames, bnames):
    out = []
    with open(path) as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            p = line.rstrip("\n").split("\t")
            if len(p) < 8 or p[0] != source:
                continue
            hc, hs, he, bc, bs, be, st = p[1], int(p[2]), int(p[3]), p[4], int(p[5]), int(p[6]), p[7]
            if named_only and (hc not in hnames or bc not in bnames):
                continue
            out.append([hc, hs, he, bc, bs, be, st])
    return out


def load_fai(path):
    L = {}
    with open(path) as fh:
        for line in fh:
            p = line.split("\t")
            if len(p) >= 2:
                L[p[0]] = int(p[1])
    return L


import re as _re
# Chromosomes we never plot (organellar / not part of the nuclear synteny view).
EXCLUDE_CHR = {"MT", "M", "MITO", "CHRM", "CHRMT"}


def chr_sort_key(name):
    # natural order: numeric chromosomes first (1,2,...,2A,2B,...), then X, Y.
    m = _re.match(r"^(?:chr)?(\d+)([A-Za-z]*)$", name)
    if m:
        return (0, int(m.group(1)), m.group(2))
    u = name.upper().replace("CHR", "")
    return (1, {"X": 1, "Y": 2}.get(u, 99), name)


def build_layout(accs, names, lengths, gap_frac, named_only=True, order=None):
    """Order accessions and assign x offsets with gaps.
    With named_only, restrict to assembled-molecule chromosomes (present in the
    name map). If `order` (a dict acc->rank) is given, sort by it (used to face
    homologous chromosomes); otherwise sort by chromosome label.
    Returns (offset[acc], total_width, ordered[(acc,label,len)])."""
    items = [(a, names.get(a, a), lengths.get(a, 0)) for a in accs
             if lengths.get(a, 0) > 0 and ((a in names) or not named_only)
             and names.get(a, a).upper().replace("CHR", "") not in EXCLUDE_CHR]
    if order is not None:
        items.sort(key=lambda t: (order.get(t[0], (9, 9e18)), chr_sort_key(t[1])))
    else:
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
    ap.add_argument("--all-contigs", action="store_true",
                    help="include unplaced scaffolds (default: assembled chromosomes only)")
    ap.add_argument("--face", action="store_true",
                    help="reorder bonobo to face its human homolog (NCBI-style clean vertical "
                         "ribbons). Default OFF keeps natural order 1,2,...,X,Y")
    ap.add_argument("--order-ref", default=None,
                    help="compute the bonobo facing order from THIS blocks file (a fixed "
                         "reference, e.g. the NCBI truth) instead of the plotted blocks, so the "
                         "bonobo order is identical across every plot/comparison")
    ap.add_argument("--order-ref-source", default="ncbi")
    ap.add_argument("--top-label", default="Pan paniscus", help="label for the y1 (top) genome bar")
    ap.add_argument("--bottom-label", default="Homo sapiens", help="label for the y2 (bottom) genome bar")
    args = ap.parse_args()
    named_only = not args.all_contigs

    hnames, bnames = load_names(args.human_names), load_names(args.bonobo_names)
    hlen, blen = load_fai(args.human_fai), load_fai(args.bonobo_fai)

    blocks = parse_blocks(args.blocks, args.source, named_only, hnames, bnames)
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

    # CANONICAL layout: lay out ALL assembled chromosomes (from the name maps),
    # in fixed natural order (1,2,...,X,Y), so each species' chromosomes always
    # sit in the SAME place regardless of which dataset/comparison is plotted.
    haccs = set(hnames.keys()); baccs = set(bnames.keys())
    hoff, hwidth, hitems = build_layout(haccs, hnames, hlen, args.gap_frac, named_only)

    # Optional (off by default): reorder bonobo to face its human homolog.
    border = None
    if args.face:
        # Facing order from a FIXED reference (so it's identical across plots),
        # or from the plotted blocks if no reference given.
        ref_blocks = blocks
        if args.order_ref:
            ref_blocks = parse_blocks(args.order_ref, args.order_ref_source, named_only, hnames, bnames)
        hrank = {a: i for i, (a, _lab, _ln) in enumerate(hitems)}
        bp_by, hmean = {}, {}
        for hc, hs, he, bc, bs, be, st in ref_blocks:
            bp_by.setdefault(bc, {}); bp_by[bc][hc] = bp_by[bc].get(hc, 0) + (he - hs)
            m = hmean.setdefault(bc, [0.0, 0]); m[0] += (hs + he) / 2.0; m[1] += 1
        border = {bc: (hrank.get(max(d, key=d.get), 99), hmean[bc][0] / max(hmean[bc][1], 1))
                  for bc, d in bp_by.items()}

    boff, bwidth, bitems = build_layout(baccs, bnames, blen, args.gap_frac, named_only, order=border)

    # Drop blocks whose chromosome isn't in the canonical layout (e.g. MT).
    blocks = [b for b in blocks if b[0] in hoff and b[3] in boff]
    # Normalize EACH genome to the same full width so both bars span [0,W] edge
    # to edge (NCBI layout). Centering each genome independently leaves a side
    # gap and makes the chromosomes look dislocated.
    W = 1.0
    hscale = W / hwidth if hwidth else 1.0
    bscale = W / bwidth if bwidth else 1.0

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
        hx0 = (hoff[hc] + hs) * hscale; hx1 = (hoff[hc] + he) * hscale
        bx0 = (boff[bc] + bs) * bscale; bx1 = (boff[bc] + be) * bscale
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
    def draw_bar(items, scale, off, ybar, genome_label):
        for a, lab, ln in items:
            x = off[a] * scale; w = ln * scale
            ax.add_patch(Rectangle((x, ybar[0]), w, ybar[1] - ybar[0],
                                   facecolor="#dddddd", edgecolor="#333333", lw=0.6, zorder=5))
            ax.text(x + w / 2, (ybar[0] + ybar[1]) / 2, lab, ha="center", va="center",
                    fontsize=7, zorder=6)
        ax.text(-0.01 * W, (ybar[0] + ybar[1]) / 2, genome_label, ha="right", va="center",
                fontsize=9, style="italic")

    draw_bar(bitems, bscale, boff, y_b, args.top_label)
    draw_bar(hitems, hscale, hoff, y_h, args.bottom_label)

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
