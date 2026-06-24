#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    vcd_window
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : vcd_window.py
# Module Description : Sample VCD signals over a time window, one row per
#                      clock edge. Used for post-sim waveform inspection.
#----------------------------------------------------------------------------
"""
vcd_window.py — sample VCD signals over a time window, one row per clock edge.

Examples:
  ./vcd_window.py simv.vcd --from 11400 --to 11500 \\
      --gtkw ../run/load_waveforms_fused_sram.gtkw
  ./vcd_window.py simv.vcd --from 114000 --to 115000 --unit ps \\
      --signals dut.arb,dut.a_hreadyout_o,dut.b_state
  ./vcd_window.py simv.vcd --list-signals dut.

Times are in ns unless --unit ps is given.  Signal names may be unqualified
suffixes (e.g. 'dut.arb') — any unique match against the full hierarchical
path is accepted.

Output: one row per posedge of --clk (default: any signal whose name ends in
'free_clk') inside the window; columns are the requested signals.  Multi-bit
signals are shown in hex; 1-bit signals as 0/1/x/z.
"""
from __future__ import annotations
import argparse
import re
import sys
from pathlib import Path


# --------------------------------------------------------------------------- #
# helpers                                                                     #
# --------------------------------------------------------------------------- #

UNIT_PS = {'ps': 1, 'ns': 1_000, 'us': 1_000_000, 'ms': 1_000_000_000, 's': 1_000_000_000_000}


def parse_time_arg(s: str, default_unit: str) -> float:
    s = s.strip().lower()
    m = re.match(r'^([\d.]+)\s*(ps|ns|us|ms|s)?$', s)
    if not m:
        raise ValueError(f"bad time: {s!r}")
    v = float(m.group(1))
    u = m.group(2) or default_unit
    return v * UNIT_PS[u]


def bin_to_hex(bits: str, width: int) -> str:
    """Convert VCD binary value to hex; preserve x/z by emitting them."""
    if any(c in 'xz' for c in bits.lower()):
        return bits  # leave 4-state as binary so x/z are visible
    # left-pad to width
    bits = bits.zfill(width)
    val = int(bits, 2)
    nyb = (width + 3) // 4
    return f"{val:0{nyb}x}"


# --------------------------------------------------------------------------- #
# .gtkw parsing                                                               #
# --------------------------------------------------------------------------- #

def read_gtkw(path: Path) -> list[str]:
    """Return list of full hierarchical signal paths from a .gtkw file."""
    sigs: list[str] = []
    seen: set[str] = set()
    for line in path.read_text().splitlines():
        s = line.strip()
        if not s or s[0] in '@[*#':
            continue
        if s == '-':
            continue
        # 'tb.dut.foo' or 'tb.dut.foo[31:0]'
        m = re.match(r'^([\w./:$]+?)(\[\d+:\d+\])?$', s)
        if not m:
            continue
        name = m.group(1)
        if '.' not in name:
            continue
        if name not in seen:
            sigs.append(name)
            seen.add(name)
    return sigs


# --------------------------------------------------------------------------- #
# VCD parser                                                                  #
# --------------------------------------------------------------------------- #

class VCD:
    def __init__(self, path: Path):
        self.path = path
        self.timescale_ps: int = 1
        self.name_to_id: dict[str, str] = {}
        self.id_width: dict[str, int] = {}
        self._body_offset: int = 0

    def parse_header(self) -> None:
        scope: list[str] = []
        header_chunks: list[str] = []
        with self.path.open() as f:
            while True:
                line = f.readline()
                if not line:
                    raise RuntimeError("VCD ended in header")
                header_chunks.append(line)
                if '$enddefinitions' in line:
                    # consume through the matching $end (may be on next line)
                    while '$end' not in line:
                        line = f.readline()
                        header_chunks.append(line)
                    self._body_offset = f.tell()
                    break
        toks = re.findall(r'\$\w+|\S+', ''.join(header_chunks))
        i = 0
        while i < len(toks):
            t = toks[i]
            if t == '$timescale':
                j = i + 1
                buf = []
                while toks[j] != '$end':
                    buf.append(toks[j])
                    j += 1
                s = ''.join(buf)
                m = re.match(r'(\d+)(ps|ns|us|ms|s)', s)
                if not m:
                    raise RuntimeError(f"bad $timescale: {s!r}")
                self.timescale_ps = int(m.group(1)) * UNIT_PS[m.group(2)]
                i = j + 1
            elif t == '$scope':
                # $scope <type> <name> $end
                scope.append(toks[i + 2])
                while toks[i] != '$end':
                    i += 1
                i += 1
            elif t == '$upscope':
                scope.pop()
                while toks[i] != '$end':
                    i += 1
                i += 1
            elif t == '$var':
                # $var <type> <width> <id> <name> [<bitrange>] $end
                w = int(toks[i + 2])
                ident = toks[i + 3]
                name = toks[i + 4]
                full = '.'.join(scope + [name])
                # if duplicate (same wire dumped under multiple aliases) keep first
                self.name_to_id.setdefault(full, ident)
                self.id_width[ident] = w
                while toks[i] != '$end':
                    i += 1
                i += 1
            elif t == '$enddefinitions':
                while toks[i] != '$end':
                    i += 1
                break
            else:
                i += 1

    def resolve(self, query: str) -> str | None:
        """Map a partial signal name to a full hierarchical name (or None)."""
        if query in self.name_to_id:
            return query
        suffix = '.' + query
        cands = [n for n in self.name_to_id if n.endswith(suffix)]
        if not cands:
            # also allow a substring match as fallback
            cands = [n for n in self.name_to_id if query in n]
        if not cands:
            return None
        cands.sort(key=len)
        return cands[0]

    def list_matching(self, prefix: str) -> list[str]:
        return sorted(n for n in self.name_to_id if prefix in n)

    def sample(self,
               signals: list[str],
               clk_full: str,
               t_from_ps: float,
               t_to_ps: float,
               edge: str = 'posedge',
               ) -> list[tuple[float, dict[str, str]]]:
        clk_id = self.name_to_id[clk_full]
        sig_ids = [(s, self.name_to_id[s]) for s in signals]
        cur: dict[str, str] = {i: 'x' for i in set(self.id_width)}
        rows: list[tuple[float, dict[str, str]]] = []
        prev_clk = 'x'
        cur_t_units = 0
        ts_ps = self.timescale_ps
        want = ('0', '1') if edge == 'posedge' else ('1', '0')

        def flush(t_units: int) -> None:
            nonlocal prev_clk
            new_clk = cur.get(clk_id, 'x')
            if prev_clk == want[0] and new_clk == want[1]:
                t_ps = t_units * ts_ps
                if t_from_ps <= t_ps <= t_to_ps:
                    snap = {s: cur.get(i, 'x') for s, i in sig_ids}
                    rows.append((t_ps, snap))
            prev_clk = new_clk

        t_to_units = t_to_ps / ts_ps if ts_ps else t_to_ps
        with self.path.open() as f:
            f.seek(self._body_offset)
            for line in f:
                line = line.rstrip('\n')
                if not line:
                    continue
                c = line[0]
                if c == '#':
                    flush(cur_t_units)
                    cur_t_units = int(line[1:])
                    if cur_t_units > t_to_units:
                        break
                elif c in '01xzXZ':
                    cur[line[1:]] = c.lower()
                elif c in 'bB':
                    sp = line[1:].split(' ', 1)
                    if len(sp) == 2:
                        cur[sp[1]] = sp[0]
                elif c in 'rR':
                    sp = line[1:].split(' ', 1)
                    if len(sp) == 2:
                        cur[sp[1]] = sp[0]
                elif c == '$':
                    continue
            flush(cur_t_units)
        return rows


# --------------------------------------------------------------------------- #
# main                                                                        #
# --------------------------------------------------------------------------- #

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Sample VCD signals over a window.")
    ap.add_argument('vcd', type=Path, help="path to VCD file")
    ap.add_argument('--from', dest='t_from', help="window start (default ns)")
    ap.add_argument('--to',   dest='t_to',   help="window end   (default ns)")
    ap.add_argument('--unit', default='ns', choices=['ps', 'ns', 'us', 'ms'],
                    help="default unit for --from/--to (default: ns)")
    ap.add_argument('--gtkw', type=Path, help=".gtkw file with signal list")
    ap.add_argument('--signals', help="comma-separated signal names")
    ap.add_argument('--clk', default=None,
                    help="clock signal (default: first match for 'free_clk')")
    ap.add_argument('--edge', default='posedge', choices=['posedge', 'negedge'],
                    help="sample on rising or falling edge of --clk (default: posedge)")
    ap.add_argument('--list-signals', metavar='SUBSTR', default=None,
                    help="list VCD signals containing SUBSTR and exit")
    ap.add_argument('--time-fmt', default='ns', choices=['ps', 'ns'],
                    help="display time format (default: ns)")
    args = ap.parse_args(argv)

    if not args.vcd.exists():
        print(f"error: VCD not found: {args.vcd}", file=sys.stderr)
        return 1

    vcd = VCD(args.vcd)
    vcd.parse_header()

    if args.list_signals is not None:
        for n in vcd.list_matching(args.list_signals):
            print(n)
        return 0

    # gather requested signals
    queries: list[str] = []
    if args.gtkw:
        queries.extend(read_gtkw(args.gtkw))
    if args.signals:
        queries.extend(s.strip() for s in args.signals.split(',') if s.strip())
    if not queries:
        print("error: provide --gtkw and/or --signals (or use --list-signals)",
              file=sys.stderr)
        return 1

    signals: list[str] = []
    seen: set[str] = set()
    for q in queries:
        full = vcd.resolve(q)
        if full is None:
            print(f"warn: no match for signal {q!r}", file=sys.stderr)
            continue
        if full not in seen:
            signals.append(full)
            seen.add(full)
    if not signals:
        print("error: none of the requested signals matched", file=sys.stderr)
        return 1

    # clock
    if args.clk:
        clk_full = vcd.resolve(args.clk)
        if clk_full is None:
            print(f"error: clock {args.clk!r} not found", file=sys.stderr)
            return 1
    else:
        clk_full = vcd.resolve('free_clk')
        if clk_full is None:
            print("error: no free_clk found; pass --clk explicitly",
                  file=sys.stderr)
            return 1

    if args.t_from is None or args.t_to is None:
        print("error: --from and --to are required", file=sys.stderr)
        return 1
    t_from_ps = parse_time_arg(args.t_from, args.unit)
    t_to_ps   = parse_time_arg(args.t_to, args.unit)

    rows = vcd.sample(signals, clk_full, t_from_ps, t_to_ps, edge=args.edge)

    # render — short labels (last component) but keep uniqueness
    short = [s.rsplit('.', 1)[-1] for s in signals]
    labels: list[str] = []
    for full, sh in zip(signals, short):
        labels.append(full if short.count(sh) > 1 else sh)
    widths = [vcd.id_width[vcd.name_to_id[s]] for s in signals]

    time_label = f"time({args.time_fmt})"
    cols = [time_label] + labels
    cells_per_row = []
    for t_ps, snap in rows:
        if args.time_fmt == 'ns':
            t_str = f"{t_ps / 1000:.1f}"
        else:
            t_str = f"{int(t_ps)}"
        cells = [t_str]
        for s, w in zip(signals, widths):
            v = snap[s]
            if w == 1:
                cells.append(v)
            else:
                cells.append(bin_to_hex(v, w))
        cells_per_row.append(cells)

    # column widths
    col_w = [len(c) for c in cols]
    for row in cells_per_row:
        for i, c in enumerate(row):
            if len(c) > col_w[i]:
                col_w[i] = len(c)

    def fmt_row(cells: list[str]) -> str:
        return '  '.join(c.ljust(col_w[i]) for i, c in enumerate(cells))

    print(fmt_row(cols))
    print('  '.join('-' * w for w in col_w))
    for row in cells_per_row:
        print(fmt_row(row))

    print(f"\n{len(rows)} rows  |  clk={clk_full}  |  "
          f"window=[{t_from_ps/1000:.1f}ns, {t_to_ps/1000:.1f}ns]  |  "
          f"timescale={vcd.timescale_ps}ps", file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
