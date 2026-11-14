"""Repository-specific settings of cov_const.py (apb_spi).

TOP                 top module elaborated by Yosys
rtl_files()         RTL sources, absolute paths (filelist.f, nested -f followed)
coverage_configs()  [(label, {PARAM: value})] -- every DUT parameterisation the
                    coverage sweep (runcov = run_all) builds; a bit is waived only
                    if it is constant in all of them: the SIM_CONFIGS builds of
                    sim_configs.py, their SPI_TB_* defines mapped to parameters.
"""
import os, sys

_BIN = os.path.dirname(os.path.abspath(__file__))
RTL_DIR = os.path.normpath(os.path.join(_BIN, '..', '..', '..', 'rtl', 'verilog'))

TOP = 'apb_spi'


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
    'SPI_TB_LANES_MAX':    'LANES_MAX',
    'SPI_TB_CS_NR':        'CS_NR',
    'SPI_TB_RX_EN':        'RX_EN',
    'SPI_TB_POLL_EN':      'POLL_EN',
    'SPI_TB_TX_FIFO_AW':   'TX_FIFO_AW',
    'SPI_TB_RX_FIFO_AW':   'RX_FIFO_AW',
    'SPI_TB_ADDRW':        'ADDRW',
    'SPI_TB_ASYNC_RST_EN': 'ASYNC_RST_EN',
}


def _param(define, value):
    if define == 'SPI_TB_MDELEG_RST':
        return 'MDELEG_RST', "9'h%03x" % int(value)
    if define == 'SPI_TB_DBG_MASK':
        return 'DBG_PMASTER_MASK', "4'b{:04b}".format(int(value))
    return _DEFINE_TO_PARAM[define], value


def coverage_configs():
    sys.path.insert(0, _BIN)
    from sim_configs import SIM_CONFIGS
    # SPI_TB_FREE_CLK is a bench setting, not a DUT parameter
    return [(label, dict(_param(d, v) for d, v in defines.items() if d != 'SPI_TB_FREE_CLK'))
            for label, defines, _ in SIM_CONFIGS]
