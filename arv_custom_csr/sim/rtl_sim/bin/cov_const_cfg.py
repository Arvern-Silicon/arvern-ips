"""Repository-specific settings of cov_const.py (arv_custom_csr).

TOP                 top module elaborated by Yosys
rtl_files()         RTL sources, absolute paths (filelist.f, nested -f followed)
coverage_configs()  [(label, {PARAM: value})] -- every DUT parameterisation the
                    coverage sweep (runcov = run_all) builds: the bench's default
                    register counts (FIXED_TESTS, both reset styles) and every
                    rtl_configs_defines.py line (SWEEP_TESTS). A bit is waived only if
                    it is constant in every build that has it.
"""
import os, re, subprocess, sys

_BIN = os.path.dirname(os.path.abspath(__file__))
RTL_DIR = os.path.normpath(os.path.join(_BIN, '..', '..', '..', 'rtl', 'verilog'))
_TB = os.path.normpath(os.path.join(_BIN, '..', '..', '..', 'bench', 'verilog', 'tb_arv_custom_csr.v'))

TOP = 'arv_custom_csr'


def _read(flist):
    out, base = [], os.path.dirname(flist)
    for l in open(flist):
        l = l.strip()
        if not l or l.startswith('//') or l.startswith('+'):
            continue
        if l.startswith('-f'):
            out += _read(os.path.normpath(os.path.join(base, l[2:].strip())))
        elif not l.startswith('-'):
            out.append(os.path.normpath(os.path.join(base, l)))
    return out


def rtl_files():
    return _read(os.path.join(RTL_DIR, 'filelist.f'))


def coverage_configs():
    bench = {m.group(1): int(m.group(2)) for m in
             re.finditer(r'`define\s+(NR_\w+)\s+(\d+)', open(_TB).read())}
    out = [('bench_default', dict(bench, ASYNC_RST_EN=1)), ('bench_sync', dict(bench, ASYNC_RST_EN=0))]
    lines = subprocess.run([sys.executable, os.path.join(_BIN, 'rtl_configs_defines.py')],
                           capture_output=True, text=True, check=True).stdout.splitlines()
    for line in lines:
        label, d = line.split(':', 1)
        p = {k: int(v) for k, v in re.findall(r'-D\s*(\w+)=(\d+)', d)}
        out.append((label, p))
    return out
