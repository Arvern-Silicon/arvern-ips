"""Repository-specific settings of cov_const.py (ahb_interconnect).

TOP                 default top module (unused: every build names its own)
rtl_files()         RTL sources, absolute paths (filelist.f, nested -f followed)
coverage_configs()  [(label, {PARAM: value}, top)] -- every DUT the coverage sweep
                    (runcov = run_all) builds, with the parameters its bench passes;
                    a bit is waived only if it is constant in all of them.
                    Mirrors bench/verilog/tb_ahb_interconnect.v and the unit benches.
"""
import os

_BIN = os.path.dirname(os.path.abspath(__file__))
RTL_DIR = os.path.normpath(os.path.join(_BIN, '..', '..', '..', 'rtl', 'verilog'))

TOP = 'ahb_interconnect_generic'


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
    gen = dict(NR_M=3, NR_S=4, HAUSER_W=1, M_HMASTER_TAG="12'h080")
    hip = dict(NR_M=2, NR_S_X=2, NR_S_NX=2, HAUSER_W=1, M_NX_HMASTER_TAG="8'h08")
    fus = dict(NR_M=2, NR_S_X_ROM=1, NR_S_X_SRAM=1, NR_S_NX=2, HAUSER_W=1, M_NX_HMASTER_TAG="8'h08")
    out = []
    for arst in (1, 0):
        out.append(('generic_arst%d' % arst, dict(gen, ASYNC_RST_EN=arst), 'ahb_interconnect_generic'))
        out.append(('hiperf_arst%d' % arst, dict(hip, ASYNC_RST_EN=arst), 'ahb_interconnect_hiperf'))
        out.append(('fused_arst%d' % arst, dict(fus, ASYNC_RST_EN=arst, FIXED_B_PRIO=0), 'ahb_interconnect_fused'))
    out.append(('fused_fixb', dict(fus, ASYNC_RST_EN=1, FIXED_B_PRIO=1), 'ahb_interconnect_fused'))
    out.append(('unit_dflt_sub', {}, 'ahb_default_subordinate'))
    for fb in (0, 1):
        out.append(('unit_rom_fb%d' % fb, dict(FIXED_B_PRIO=fb), 'ahb_fused_rom_ctrl'))
        out.append(('unit_sram_fb%d' % fb, dict(FIXED_B_PRIO=fb), 'ahb_fused_sram_ctrl'))
    return out
