"""Repository-specific settings of cov_const.py (arv_dtm).

TOP                 top module elaborated by Yosys
rtl_files()         RTL sources, absolute paths (filelist.f, nested -f followed)
coverage_configs()  [(label, {PARAM: value})] -- every DUT parameterisation the
                    coverage sweep (runcov) builds; a bit is waived only if it is
                    constant in all of them. Mirrors bench/verilog/tb_arv_dtm.v.
"""
import os

_BIN = os.path.dirname(os.path.abspath(__file__))
RTL_DIR = os.path.normpath(os.path.join(_BIN, '..', '..', '..', 'rtl', 'verilog'))

TOP = 'arv_dtm'

# tb_arv_dtm.v DUT parameters in a coverage build (asynchronous reset, default defines)
_BENCH = dict(IDCODE_BASE="28'h00001F7", IDLE_HINT="3'd3", I2C_ADDR="7'h30", ARST_EN="1'b1",
              AB_BREAK_CLKS="32'd700", UART_RX_FIFO_DEPTH=32)


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
    def c(**kw):
        d = dict(_BENCH)
        d.update(kw)
        return d
    return [('jtag', c(DTM_TYPE=0)),
            ('jtag_idcode_alt', c(DTM_TYPE=0, IDCODE_BASE="28'hAAAAAAB")),   # idcode_alt (+define+IDCODE_ALT)
            ('uart', c(DTM_TYPE=1)),
            ('uart_slow_baud', c(DTM_TYPE=1, AB_BREAK_CLKS="32'd65536")),     # uart_slow_baud (+define+SLOW_BAUD)
            ('i2c', c(DTM_TYPE=2)),
            ('cjtag', c(DTM_TYPE=3))]
