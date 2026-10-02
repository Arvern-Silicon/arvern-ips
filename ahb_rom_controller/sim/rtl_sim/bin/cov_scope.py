#!/usr/bin/env python3
"""Write a Verilator config that limits coverage to the DUT RTL.

    cov_scope.py <out.vlt> <filelist> <dut_dir> [<dut_dir> ...]

Every source file and +incdir+ directory of <filelist> (-f nesting followed, paths
relative to the list that names them) that is NOT under one of the <dut_dir>s gets a
`coverage_off`. Verilator 5.052 no longer lets `coverage_on -file` re-enable files
after a blanket `coverage_off -file "*"`, so the scope is built by exclusion.
"""
import os
import sys


def walk(flist, files, dirs):
    base = os.path.dirname(os.path.abspath(flist))
    for raw in open(flist):
        l = raw.strip()
        if not l or l.startswith('//'):
            continue
        if l.startswith('-f'):
            walk(os.path.normpath(os.path.join(base, l[2:].strip())), files, dirs)
        elif l.startswith('+incdir+'):
            for d in l[len('+incdir+'):].split('+'):
                if d:
                    dirs.add(os.path.normpath(os.path.join(base, d)))
        elif not l.startswith(('-', '+')):
            files.add(os.path.normpath(os.path.join(base, l)))


def main():
    out, flist, duts = sys.argv[1], sys.argv[2], [os.path.normpath(os.path.abspath(d)) for d in sys.argv[3:]]
    files, dirs = set(), set()
    walk(flist, files, dirs)
    dirs |= {os.path.dirname(f) for f in files}
    inside = lambda p: any(p == d or p.startswith(d + os.sep) for d in duts)
    lines = ['`verilator_config']
    lines += ['coverage_off -file "%s/*"' % d for d in sorted(dirs) if not inside(d)]
    lines += ['coverage_off -file "%s"' % f for f in sorted(files) if not inside(f)]
    with open(out, 'w') as fh:
        fh.write('\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
