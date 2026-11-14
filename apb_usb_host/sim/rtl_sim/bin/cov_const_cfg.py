"""Repository-specific settings of cov_const.py (apb_usb_host).

TOP                 top module elaborated by Yosys
rtl_files()         RTL sources, absolute paths (filelist.f, nested -f followed)
coverage_configs()  [(label, {PARAM: value})] -- every DUT parameterisation the
                    coverage sweep (runcov = run_all) builds; a bit is waived only
                    if it is constant in all of them: the SIM_CONFIGS builds of
                    sim_configs.py, their USB_TB_* defines mapped to parameters.
"""
import os, sys

_BIN = os.path.dirname(os.path.abspath(__file__))
RTL_DIR = os.path.normpath(os.path.join(_BIN, '..', '..', '..', 'rtl', 'verilog'))

TOP = 'apb_usb_host'


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


_DEFINE_TO_PARAM = {
    'USB_TB_CLK_HZ':       'CLK_HZ',
    'USB_TB_CTRL_EN':      'CTRL_EN',
    'USB_TB_DIAG_EN':      'DIAG_EN',
    'USB_TB_ADDRW':        'ADDRW',
    'USB_TB_ASYNC_RST_EN': 'ASYNC_RST_EN',
}


def _param(define, value):
    if define == 'USB_TB_MDELEG_RST':
        return 'MDELEG_RST', "9'h%03x" % int(value)
    return _DEFINE_TO_PARAM[define], value


def coverage_configs():
    sys.path.insert(0, _BIN)
    from sim_configs import SIM_CONFIGS
    # USB_TB_FREE_CLK is a bench setting, not a DUT parameter
    return [(label, dict(_param(d, v) for d, v in defines.items() if d != 'USB_TB_FREE_CLK'))
            for label, defines, _ in SIM_CONFIGS]
