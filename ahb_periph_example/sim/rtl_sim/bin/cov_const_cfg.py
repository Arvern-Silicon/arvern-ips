"""Repository-specific settings of cov_const.py (ahb_periph_example).

TOP                 top module elaborated by Yosys
rtl_files()         RTL sources, absolute paths (filelist.f, nested -f followed)
coverage_configs()  [(label, {PARAM: value})] -- every DUT parameterisation the
                    coverage sweep (runcov = run_all) builds; a bit is waived only
                    if it is constant in all of them. Mirrors rtl_configs.CONFIGS.
"""
import os, sys

_BIN = os.path.dirname(os.path.abspath(__file__))
RTL_DIR = os.path.normpath(os.path.join(_BIN, '..', '..', '..', 'rtl', 'verilog'))

TOP = 'ahb_periph_example'


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
    sys.path.insert(0, _BIN)
    from rtl_configs import CONFIGS
    return [(label, dict(p)) for label, p in CONFIGS]
