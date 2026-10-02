#!/usr/bin/env python3
"""cov_vlfix.py <mdir> -- place a corrected verilated_cov.h in a Verilator build directory.

Verilator's VL_COV_TOGGLE_CHG_{ST,MT}_W (toggle coverage of vectors wider than 64 bits)
bounds its per-word bit loop by the remaining vector width instead of the 32-bit word
size, and shifts a 32-bit word by 32 or more. On arm64 the shift wraps, so a toggle of
bit b in word w is also credited to bit b of every higher word: phantom coverage on
every signal wider than 64 bits (Verilator 5.052).

The generated model includes "verilated_cov.h" with quotes from the build directory, so
a corrected copy there takes precedence over the installed one. The copy is made from
the installed header with only the loop bound changed; when the installed header no
longer has the faulty bound nothing is written. Run it before `verilator --Mdir <mdir>`.
"""
import os
import subprocess
import sys

BAD = 'for (int j = 0; j < width - i * VL_EDATASIZE; ++j) {'
GOOD = ('for (int j = 0; j < ((width - i * VL_EDATASIZE) < VL_EDATASIZE'
        ' ? (width - i * VL_EDATASIZE) : VL_EDATASIZE); ++j) {')


def main(mdir):
    root = subprocess.run(['verilator', '--getenv', 'VERILATOR_ROOT'],
                          capture_output=True, text=True).stdout.strip()
    src = os.path.join(root, 'include', 'verilated_cov.h')
    if not os.path.exists(src):
        return 0
    txt = open(src).read()
    if BAD not in txt:
        return 0
    os.makedirs(mdir, exist_ok=True)
    with open(os.path.join(mdir, 'verilated_cov.h'), 'w') as fh:
        fh.write(txt.replace(BAD, GOOD))
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1]))
