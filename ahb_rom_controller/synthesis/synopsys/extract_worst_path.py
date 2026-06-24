#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    extract_worst_path
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : extract_worst_path.py
# Module Description : Print the worst (or N worst) timing paths from a
#                      Synopsys DC 'report_timing -path full' output file.
#----------------------------------------------------------------------------
"""
extract_worst_path.py  -  Print the worst (or N worst) timing paths from a
Synopsys DC 'report_timing -path full' output file.

Usage:
    python3 extract_worst_path.py [-short] [report_file] [N]

Options:
    -short       Print only the top-10 summary table; skip detailed paths.

Defaults:
    report_file  : results/report.full_paths.max
    N            : 1   (print only the single worst path in detail)
"""

import re
import sys
import os

# Parse args: -short is an optional flag, positional args are [report_file] [N].
_args = sys.argv[1:]
SHORT = False
if '-short' in _args:
    SHORT = True
    _args.remove('-short')

REPORT_FILE = _args[0] if len(_args) > 0 else \
    os.path.join(os.path.dirname(__file__), "results/report.full_paths.max")
N_PATHS = int(_args[1]) if len(_args) > 1 else 1

if not os.path.isfile(REPORT_FILE):
    print(f"extract_worst_path.py: report file not found: {REPORT_FILE}")
    print(f"  (run ./run_syn first, or pass a different path as the first argument)")
    sys.exit(1)

with open(REPORT_FILE) as f:
    content = f.read()

# Slice content into per-path blocks starting at each 'Startpoint:' line.
# (Using finditer + manual slicing rather than re.split with a zero-width
# lookahead, which raises ValueError on Python 3.6.)
_starts = [m.start() for m in re.finditer(r'[ \t]+Startpoint:', content)]
raw_blocks = [content[_starts[i] : (_starts[i+1] if i+1 < len(_starts) else len(content))]
              for i in range(len(_starts))]

paths = []
for blk in raw_blocks:
    slack_m  = re.search(r'slack\s+\((?P<status>MET|VIOLATED)\)\s+(?P<val>[-\d.]+)', blk)
    start_m  = re.search(r'Startpoint\s*:\s+(\S+)', blk)
    end_m    = re.search(r'Endpoint\s*:\s+(\S+)',   blk)
    if slack_m and start_m and end_m:
        paths.append({
            'slack'  : float(slack_m.group('val')),
            'status' : slack_m.group('status'),
            'start'  : start_m.group(1),
            'end'    : end_m.group(1),
            'text'   : blk.rstrip(),
        })

paths.sort(key=lambda p: p['slack'])

print(f"  {'#':<4} {'Slack':>8}  {'Status':<10}  Startpoint -> Endpoint")
print("  " + "-" * 100)
summary_count = min(10, len(paths)) if SHORT else len(paths)
for i, p in enumerate(paths[:summary_count]):
    tag = "[VIOLATED]" if p['status'] == 'VIOLATED' else "[MET]     "
    print(f"  {i+1:<4} {p['slack']:>+8.3f}  {tag}  {p['start']}  ->  {p['end']}")
print()

if not SHORT:
    for i in range(min(N_PATHS, len(paths))):
        p = paths[i]
        print("=" * 78)
        print(f"  PATH {i+1}  slack={p['slack']:+.3f} ({p['status']})")
        print("=" * 78)
        print(p['text'])
        print()
