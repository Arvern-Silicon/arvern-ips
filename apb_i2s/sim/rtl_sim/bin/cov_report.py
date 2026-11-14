#!/usr/bin/env python3
"""Summarise Verilator coverage databases produced by runcov.

Verilator writes one point per (file, line, hierarchy, page-type); a point is
covered if any test hit it. Toggle points dominate by count, so line, branch and
toggle are reported separately rather than merged into one figure.

Only rtl/verilog/ is reported -- bench coverage is not a design metric.
"""
import sys
import glob
import re
import os
import collections
import cov_waive

PAGES = ('v_line', 'v_branch', 'v_toggle')


_DIR = re.compile(r':(?:0->1|1->0)(?=\x01|$)')


def parse(datdir, rtl_pats=('/rtl/verilog/',)):
    """Return {point_key: (page, file, max_count)} across every database."""
    pts = {}
    for fn in glob.glob(os.path.join(datdir, '*.dat')):
        with open(fn, encoding='utf-8', errors='replace') as fh:
            for ln in fh:
                if not ln.startswith("C '"):
                    continue
                key, _, cnt = ln[3:].rpartition("' ")
                try:
                    c = int(cnt.strip())
                except ValueError:
                    continue
                d = {}
                for fld in key.split('\x01'):
                    if '\x02' in fld:
                        k, v = fld.split('\x02', 1)
                        d[k] = v
                path = d.get('f', '')
                if not any(pat in path for pat in rtl_pats):
                    continue
                page = d.get('page', '').split('/')[0]
                prev = pts.get(key)
                pts[key] = (page, path, max(prev[2], c) if prev else c)
    # Verilator >= 5.04x records each toggle bit as two points, `sig:0->1` and `sig:1->0`.
    # Fold them back into one point per bit, keyed like the older single point (so
    # waivers and tools keep one name per bit), counted as the SMALLER direction: a bit
    # is covered only once it has both risen and fallen.
    folded = {}
    for key, (page, path, c) in pts.items():
        base = _DIR.sub('', key)
        if base == key:
            folded[key] = (page, path, c)
        else:
            prev = folded.get(base)
            folded[base] = (page, path, min(prev[2], c) if prev else c)
    # Two line/branch points on one line with one label (a chained ternary gives several
    # cond_else) are told apart only by their column `n`. Name them `label@n`, or the
    # per-location view and the waivers merge them and a covered point hides an
    # uncovered twin. A label with no twin keeps its plain name.
    cols = collections.defaultdict(set)
    for key, (page, path, c) in folded.items():
        if page in ('v_line', 'v_branch'):
            d = dict(f.split('\x02', 1) for f in key.split('\x01') if '\x02' in f)
            cols[(path, d.get('l'), d.get('o'))].add(d.get('n'))
    out = {}
    for key, v in folded.items():
        if v[0] in ('v_line', 'v_branch'):
            d = dict(f.split('\x02', 1) for f in key.split('\x01') if '\x02' in f)
            if len(cols[(v[1], d.get('l'), d.get('o'))]) > 1:
                key = key.replace('\x01o\x02%s\x01' % d.get('o'), '\x01o\x02%s@%s\x01' % (d.get('o'), d.get('n')), 1) \
                    if ('\x01o\x02%s\x01' % d.get('o')) in key else key + '@%s' % d.get('n')
        out[key] = v
    return out


def main(datdir, per_instance=False, waiver_path=None, rtl_pats=('/rtl/verilog/',)):
    pts = parse(datdir, rtl_pats)
    wv = cov_waive.Waivers(waiver_path)
    for e in wv.errors:
        print("WAIVER ERROR: %s" % e)
    if wv.errors:
        return 1
    if not per_instance:
        # Accumulate to SOURCE locations: one point per (file, line, page, signal),
        # covered if any elaborated instance hit it. This is the "did the regression
        # reach this code" view. --per-instance keeps every elaborated copy separate,
        # which finds config gaps (hit in the UART build, not the I2C one).
        acc = {}
        for key, (page, path, cnt) in pts.items():
            d = {}
            for fld in key.split('\x01'):
                if '\x02' in fld:
                    k, v = fld.split('\x02', 1)
                    d[k] = v
            k2 = (path, d.get('l', ''), page, d.get('o', ''), d.get('n', ''))
            prev = acc.get(k2)
            acc[k2] = (page, path, max(prev[2], cnt) if prev else cnt)
        pts = acc
    if not pts:
        print("ERROR: no coverage points found in %s" % datdir)
        return 1

    waived = collections.Counter()
    kept = {}
    for k, (page, path, cnt) in pts.items():
        line = int(k[1] or 0) if isinstance(k, tuple) else \
               next((int(f[2:]) for f in k.split('\x01') if f.startswith('l\x02')), 0)
        sig = k[3] if isinstance(k, tuple) else \
              next((f[2:] for f in k.split('\x01') if f.startswith('o\x02')), '')
        if wv.match(path, line, page, sig):
            waived[os.path.basename(path)] += 1
            continue
        kept[k] = (page, path, cnt)
    pts = kept

    warn = cov_waive.check_fresh(datdir, {v[1] for v in pts.values()}
                                 if not isinstance(next(iter(pts)), tuple)
                                 else {k[0] for k in pts})
    if warn:
        print("  WARNING: %s" % warn)

    agg = collections.defaultdict(lambda: collections.defaultdict(lambda: [0, 0]))
    for page, path, cnt in pts.values():
        e = agg[os.path.basename(path)][page]
        e[1] += 1
        e[0] += (cnt > 0)

    tot = collections.defaultdict(lambda: [0, 0])
    rows = []
    for name, d in agg.items():
        cells = []
        for page in PAGES:
            hit, found = d[page]
            tot[page][0] += hit
            tot[page][1] += found
            cells.append("%d/%d %d%%" % (hit, found, 100 * hit / found) if found else "-")
        lh, lf = d['v_line']
        rows.append((100.0 * lh / lf if lf else 100.0, name, cells))

    print("view: %s\n" % ("per-instance" if per_instance else "accumulated (source locations)"))
    print("%-24s%12s%13s%14s" % ("file", "line", "branch", "toggle"))
    print("-" * 63)
    for _, name, cells in sorted(rows):
        print("%-24s%12s%13s%14s" % (name, cells[0], cells[1], cells[2]))
    print("-" * 63)
    print("%-24s" % "RTL TOTAL" + "".join(
        ("%d/%d %.1f%%" % (tot[p][0], tot[p][1], 100.0 * tot[p][0] / tot[p][1])).rjust(w)
        for p, w in zip(PAGES, (12, 13, 14))))

    # Uncovered line/branch points, collapsed to source locations (a line can appear
    # once per instance; the location is what a reader can act on).
    loc = {}
    for key, (page, path, cnt) in pts.items():
        if page == 'v_toggle':
            continue
        if isinstance(key, tuple):          # accumulated: (path, line, page, o, n)
            line = int(key[1] or 0)
        else:                               # per-instance: the raw database key
            line = 0
            for fld in key.split('\x01'):
                if fld.startswith('l\x02'):
                    line = int(fld[2:])
        # Key on the KIND too. Collapsing to (file, line, page) takes the max across
        # points on that line, so a covered `if` masks its uncovered `else` and the
        # list silently disagrees with the totals.
        kind = key[3] if isinstance(key, tuple) else \
               next((f[2:] for f in key.split('\x01') if f.startswith('o\x02')), '')
        k = (os.path.basename(path), line, page, kind)
        loc[k] = max(loc.get(k, 0), cnt)

    missing = sorted(k for k, c in loc.items() if c == 0)
    if missing:
        print("\nUncovered line/branch source locations (%d):" % len(missing))
        for name, line, page, kind in missing:
            print("   %-24s :%-5d %-7s %s" % (name, line, page.replace('v_', ''), kind))
    else:
        print("\nAll line and branch points covered.")

    if sum(waived.values()):
        print("\nWaived (excluded from the totals above): %d points" % sum(waived.values()))
        for name, n in sorted(waived.items()):
            print("   %-24s %d" % (name, n))
    for w in wv.stale():
        print("STALE WAIVER: %s matched nothing  (%s) -- %s" % (w, w.src, w.reason))
    return 0


if __name__ == '__main__':
    argv = [a for a in sys.argv[1:] if a != '--per-instance']
    # --rtl PAT restricts the report to source paths containing PAT (repeatable).
    # Default keeps every rtl/verilog/ tree; pass the DUT's own path to exclude IPs.
    pats = [sys.argv[i + 1] for i, a in enumerate(sys.argv) if a == '--rtl']
    if pats:
        argv = [a for a in argv if a != '--rtl' and a not in pats]
    rtl_pats = tuple(pats) if pats else ('/rtl/verilog/',)

    # --suggest <file>:<line> [type]   emit ready-to-paste waiver entries
    # --lint                           check every waiver against the database
    if '--suggest' in sys.argv:
        i = sys.argv.index('--suggest')
        spec = sys.argv[i + 1]
        kind = sys.argv[i + 2] if len(sys.argv) > i + 2 and not sys.argv[i + 2].startswith('-') else None
        f, _, l = spec.rpartition(':')
        datdir = argv[0] if argv and not argv[0].startswith('-') else 'dats'
        sys.exit(cov_waive.suggest(parse(datdir, rtl_pats), f, l, kind))

    if '--lint' in sys.argv:
        argv = [a for a in argv if a != '--lint']
        datdir = argv[0] if argv else 'dats'
        wv = cov_waive.Waivers(cov_waive.default_path(__file__))
        for e in wv.errors:
            print('WAIVER ERROR: %s' % e)
        # Refuse to lint against nothing. With no database EVERY waiver matches
        # zero points and is reported STALE -- the one signal that means "the RTL
        # moved underneath a waiver and a real hole may be hidden". Firing it
        # wholesale on a mistyped path is how that signal stops being believed.
        pts = parse(datdir, rtl_pats)
        if not pts:
            print('ERROR: no coverage points found in %s -- cannot lint waivers.\n'
                  '       Run the coverage regression first, or check the path '
                  '(the dats live under run/cov/dats).' % datdir)
            sys.exit(2)
        rc = cov_waive.lint(wv, pts)
        print('\n  %d waiver(s) need attention' % rc if rc else '\n  all waivers match uncovered points')
        sys.exit(1 if rc else 0)

    wp = cov_waive.default_path(__file__)
    if '-w' in sys.argv:
        wp = sys.argv[sys.argv.index('-w') + 1]
        argv = [a for a in argv if a != wp and a != '-w']
    sys.exit(main(argv[0] if argv else 'dats',
                  per_instance='--per-instance' in sys.argv,
                  waiver_path=wp, rtl_pats=rtl_pats))
