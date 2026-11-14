#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    rtl_configs.py (apb_spi)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the apb_spi RTL parameterization sweep set.
#
# Consumed by lint/vc_static/run_vclint and synthesis/synopsys/run_syn
# (-rtl_config / -rtl_sweep) through bin/gen_rtl_params.py. The simulation
# regression (sim/rtl_sim/run/run_all) runs the same builds from its own list;
# a new config goes in both.
#
# Each entry is (label, {PARAM: value}). Unspecified parameters take their
# RTL default. The label is used to name log files and the summary column.
#
# Coverage rationale, one factor at a time around the defaults (LANES_MAX=4,
# CS_NR=1, RX_EN=1, POLL_EN=1, TX_FIFO_AW=RX_FIFO_AW=4, ADDRW=7,
# MDELEG_RST=9'h10F, DBG_PMASTER_MASK=4'b1000, ASYNC_RST_EN=1) plus corners:
#   ASYNC_RST_EN      0 is the ONLY setting that builds the arv_ipdff /
#                     arv_synchronizer sync-reset branches; rules.tcl enforces
#                     the opposite reset rule for it.
#   LANES_MAX         1, 2 and 4 select the IO2 / IO3 synchronisers (g_quad_in)
#                     and the lane-code mask that prunes the dual / quad
#                     multiplexers.
#   CS_NR             sizes spi_cs_o, the select decode and CSPOL: 1 and 8.
#   RX_EN, POLL_EN    each selects a generate branch (g_rx / g_no_rx in the
#                     core and the wrapper, g_poll / g_no_poll, g_poll_regs);
#                     POLL_EN=1 with RX_EN=0 is illegal.
#   TX_FIFO_AW,
#   RX_FIFO_AW        size the FIFO pointers, storage and level padding:
#                     1 (two entries, the narrowest pointers) and 8 (256, no
#                     level padding).
#   ADDRW             7 is the minimum window; 16 the widest decoder.
#   MDELEG_RST        only the reset values of the three MDELEG flops (9'h000
#                     resets every bit to 0, 9'h105 mixes set and reset flops).
#   DBG_PMASTER_MASK  a constant in one AND: 0 removes the debugger term.
#----------------------------------------------------------------------------

CONFIGS = [
    # label            parameter overrides
    ("default",        {}),                                                  # RTL defaults
    ("sync_rst",       {"ASYNC_RST_EN": 0}),                                 # Sync reset: arv_ipdff/arv_synchronizer sync branches
    ("single",         {"LANES_MAX": 1}),                                    # Single lane: no IO2/IO3 synchronisers, no dual/quad muxes
    ("dual",           {"LANES_MAX": 2}),                                    # Dual lane
    ("cs8",            {"CS_NR": 8}),                                        # Widest select decode
    ("tx_only",        {"RX_EN": 0, "POLL_EN": 0}),                          # g_no_rx
    ("no_poll",        {"POLL_EN": 0}),                                      # g_no_poll
    ("fifo2",          {"TX_FIFO_AW": 1, "RX_FIFO_AW": 1}),                  # Narrowest FIFOs
    ("fifo256",        {"TX_FIFO_AW": 8, "RX_FIFO_AW": 8}),                  # Deepest FIFOs, no level padding
    ("open",           {"MDELEG_RST": "9'h000"}),                            # MDELEG open out of reset
    ("smode_sync_rst", {"MDELEG_RST": "9'h105", "ASYNC_RST_EN": 0}),         # Supervisor gates under sync reset
    ("addrw16",        {"ADDRW": 16}),                                       # Widest window
    ("dbg_none",       {"DBG_PMASTER_MASK": "4'b0000"}),                     # No debugger term
    ("sd_corner",      {"LANES_MAX": 1, "CS_NR": 2, "TX_FIFO_AW": 3,         # SD-card build
                        "RX_FIFO_AW": 6, "ASYNC_RST_EN": 0}),
    ("tx_only_corner", {"LANES_MAX": 2, "RX_EN": 0, "POLL_EN": 0,            # Transmit-only corner
                        "TX_FIFO_AW": 1, "CS_NR": 3, "MDELEG_RST": "9'h000"}),
]
TOP_MODULE = "apb_spi"
