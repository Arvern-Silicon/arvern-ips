"""Repository-specific settings of cov_const.py (ahb_aclint).

TOP                 top module elaborated by Yosys
rtl_files()         RTL sources, absolute paths (filelist.f, nested -f followed)
coverage_configs()  [(label, {PARAM: value})] -- every DUT parameterisation the
                    coverage sweep (runcov, = sim_configs.SIM_CONFIGS) builds; a bit
                    is waived only if it is constant in all of them. The bench maps
                    ACLINT_<PARAM> defines onto the DUT parameters with the defaults
                    below (tb_ahb_aclint.v); ACLINT_LF_HALF_PERIOD is bench-only.
"""
import os

_BIN = os.path.dirname(os.path.abspath(__file__))
RTL_DIR = os.path.normpath(os.path.join(_BIN, '..', '..', '..', 'rtl', 'verilog'))

TOP = 'ahb_aclint'

_BENCH = dict(NUM_HARTS=1, SU_MODE_EN=1, PRIV_CHECK_EN=1, LF_SYNC_EN=0, ASYNC_RST_EN=1)


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
    import sys
    sys.path.insert(0, _BIN)
    from sim_configs import SIM_CONFIGS
    seen, out = set(), []
    for label, defines, _ in SIM_CONFIGS:
        p = dict(_BENCH)
        for k, v in defines.items():
            if k.startswith('ACLINT_') and k[7:] in p:
                p[k[7:]] = v
        key = tuple(sorted(p.items()))
        if key not in seen:
            seen.add(key)
            out.append((label, p))
    return out
