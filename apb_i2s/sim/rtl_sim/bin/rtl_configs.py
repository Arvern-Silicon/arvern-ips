#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    rtl_configs.py (apb_i2s)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the apb_i2s RTL parameterization sweep set.
#
# Consumed by lint/vc_static/run_vclint and synthesis/synopsys/run_syn
# (-rtl_config / -rtl_sweep) through bin/gen_rtl_params.py. The simulation
# regression (sim/rtl_sim/run/run_all) runs the same builds from its own list;
# a new config goes in both.
#
# Each entry is (label, {PARAM: value}). Unspecified parameters take their
# RTL default. The label is used to name log files and the summary column.
#
# Coverage rationale, one factor at a time around the defaults (TX_EN=1,
# RX_EN=1, TX_FIFO_AW=RX_FIFO_AW=5, ADDRW=7, MDELEG_RST=9'h10F,
# DBG_PMASTER_MASK=4'b1000, ASYNC_RST_EN=1) plus corners:
#   ASYNC_RST_EN      0 is the ONLY setting that builds the arv_ipdff /
#                     arv_synchronizer sync-reset branches; rules.tcl enforces
#                     the opposite reset rule for it.
#   TX_EN, RX_EN      each selects a generate branch (g_tx / g_no_tx,
#                     g_rx / g_no_rx) and removes a FIFO; both 0 is illegal.
#   TX_FIFO_AW,
#   RX_FIFO_AW        size the FIFO pointers, storage and level padding:
#                     1 (two words, the narrowest pointers) and 8 (256 words,
#                     no level padding).
#   ADDRW             7 is the minimum window; 16 the widest decoder.
#   MDELEG_RST        only the reset values of the three MDELEG flops (9'h000
#                     resets every bit to 0, 9'h105 mixes set and reset flops).
#   DBG_PMASTER_MASK  a constant in one AND: 0 removes the debugger term.
#----------------------------------------------------------------------------

CONFIGS = [
    # label            parameter overrides
    ("default",        {}),                                                  # RTL defaults
    ("sync_rst",       {"ASYNC_RST_EN": 0}),                                 # Sync reset: arv_ipdff/arv_synchronizer sync branches
    ("tx_only",        {"RX_EN": 0}),                                        # g_no_rx
    ("rx_only",        {"TX_EN": 0}),                                        # g_no_tx
    ("fifo2",          {"TX_FIFO_AW": 1, "RX_FIFO_AW": 1}),                  # Narrowest FIFOs
    ("fifo256",        {"TX_FIFO_AW": 8, "RX_FIFO_AW": 8}),                  # Deepest FIFOs, no level padding
    ("open",           {"MDELEG_RST": "9'h000"}),                            # MDELEG open out of reset
    ("smode_sync_rst", {"MDELEG_RST": "9'h105", "ASYNC_RST_EN": 0}),         # Supervisor gates under sync reset
    ("addrw16",        {"ADDRW": 16}),                                       # Widest window
    ("dbg_none",       {"DBG_PMASTER_MASK": "4'b0000"}),                     # No debugger term
    ("tx_only_corner", {"RX_EN": 0, "TX_FIFO_AW": 1, "ASYNC_RST_EN": 0,      # Transmit-only corner
                        "MDELEG_RST": "9'h000"}),
    ("rx_only_corner", {"TX_EN": 0, "RX_FIFO_AW": 8, "ADDRW": 12,            # Receive-only corner
                        "DBG_PMASTER_MASK": "4'b0001"}),
]
TOP_MODULE = "apb_i2s"
