"""Repository-specific settings of cov_const.py (ahb_apb_bridge).

TOP                 top module elaborated by Yosys
rtl_files()         RTL sources, absolute paths (filelist.f, nested -f followed)
coverage_configs()  [(label, {PARAM: value})] -- every DUT parameterisation the
                    coverage sweep (runcov, = sim_configs.SIM_CONFIGS) builds; a bit
                    is waived only if it is constant in all of them. The bench maps
                    BRG_CFG / BRG_ASYNC_RST_EN onto the DUT parameters below
                    (tb_ahb_apb_bridge.v).
"""
import os

_BIN = os.path.dirname(os.path.abspath(__file__))
RTL_DIR = os.path.normpath(os.path.join(_BIN, '..', '..', '..', 'rtl', 'verilog'))

TOP = 'ahb_apb_bridge'

def _packed(fields, width):
    """Completer 0 in the low bits, as a sized hex literal (wider than 32 bits)."""
    v = 0
    for k, f in enumerate(fields):
        v |= f << (k * width)
    return "%d'h%x" % (len(fields) * width, v)


# The completer maps of the bench, by BRG_CFG
_MAPS = {
    0: dict(SLV_NR=3, ADDRW=12, SLV_BASE=_packed([0x000, 0x400, 0x800], 12), SLV_AW=_packed([8, 10, 4], 5)),
    1: dict(SLV_NR=1, ADDRW=8, SLV_BASE=_packed([0], 8), SLV_AW=_packed([8], 5)),
    2: dict(SLV_NR=16, ADDRW=16, SLV_BASE=_packed([k * 0x1000 for k in range(16)], 16), SLV_AW=_packed([12] * 16, 5)),
    3: dict(SLV_NR=3, ADDRW=12, SLV_BASE=_packed([0x000, 0x400, 0x800], 12), SLV_AW=_packed([8, 10, 2], 5)),
}


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
        p = dict(_MAPS[defines.get('BRG_CFG', 0)])
        p['ASYNC_RST_EN'] = defines.get('BRG_ASYNC_RST_EN', 1)
        key = tuple(sorted(p.items()))
        if key not in seen:
            seen.add(key)
            out.append((label, p))
    return out
