"""Repository-specific settings of cov_const.py (apb_periph_example).

TOP                 top module elaborated by Yosys
rtl_files()         RTL sources, absolute paths (filelist.f, nested -f followed)
coverage_configs()  [(label, {PARAM: value})] -- every DUT parameterisation the
                    coverage sweep (runcov, = sim_configs.SIM_CONFIGS) builds; a bit
                    is waived only if it is constant in all of them. The bench maps
                    PER_ADDRW / PER_ASYNC_RST_EN / PER_MDELEG_RST onto ADDRW /
                    ASYNC_RST_EN / MDELEG_RST (tb_apb_periph_example.v).
"""
import os

_BIN = os.path.dirname(os.path.abspath(__file__))
RTL_DIR = os.path.normpath(os.path.join(_BIN, '..', '..', '..', 'rtl', 'verilog'))

TOP = 'apb_periph_example'


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
        p = {'ADDRW': defines.get('PER_ADDRW', 7),
             'ASYNC_RST_EN': defines.get('PER_ASYNC_RST_EN', 1),
             'MDELEG_RST': defines.get('PER_MDELEG_RST', 0x10F)}
        key = tuple(sorted(p.items()))
        if key not in seen:
            seen.add(key)
            out.append((label, p))
    return out
