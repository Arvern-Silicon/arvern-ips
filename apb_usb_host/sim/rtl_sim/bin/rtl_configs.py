#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    rtl_configs.py (apb_usb_host)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the apb_usb_host RTL parameterization sweep set.
#
# Consumed by lint/vc_static/run_vclint and synthesis/synopsys/run_syn
# (-rtl_config / -rtl_sweep) through bin/gen_rtl_params.py. The simulation
# regression (sim/rtl_sim/run/run_all) runs the same builds from its own list;
# a new config goes in both.
#
# Each entry is (label, {PARAM: value}). Unspecified parameters take their
# RTL default. The label is used to name log files and the summary column.
#
# Coverage rationale, one factor at a time around the defaults (CLK_HZ=48 MHz,
# CTRL_EN=0, DIAG_EN=0, ADDRW=8, MDELEG_RST=9'h10F, ASYNC_RST_EN=1) plus corners:
#   ASYNC_RST_EN      0 is the ONLY setting that builds the arv_ipdff /
#                     arv_synchronizer sync-reset branches; rules.tcl enforces
#                     the opposite reset rule for it.
#   CLK_HZ            selects the bit-clock generator: a counter when CLK_HZ is
#                     a multiple of 1.5 MHz (12, 13.5, 36, 48 MHz), a phase
#                     accumulator otherwise (25, 33.333, 100, 200 MHz), and
#                     sizes every timer constant; 12 MHz is the minimum.
#   CTRL_EN, DIAG_EN  each selects a generate branch (g_xfer, g_diag).
#   ADDRW             8 is the minimum window; 16 the widest decoder.
#   MDELEG_RST        only the reset values of the three MDELEG flops (9'h000
#                     resets every bit to 0, 9'h105 mixes set and reset flops).
#----------------------------------------------------------------------------

CONFIGS = [
    # label            parameter overrides
    ("default",        {}),                                                  # RTL defaults: 48 MHz, counter bit clock
    ("sync_rst",       {"ASYNC_RST_EN": 0}),                                 # Sync reset: arv_ipdff/arv_synchronizer sync branches
    ("ctrl",           {"CTRL_EN": 1}),                                      # g_xfer
    ("diag",           {"DIAG_EN": 1}),                                      # g_diag
    ("full",           {"CTRL_EN": 1, "DIAG_EN": 1}),                        # Both options
    ("clk12",          {"CLK_HZ": 12000000}),                                # Minimum clock, counter
    ("clk13m5",        {"CLK_HZ": 13500000}),                                # Odd multiple of 1.5 MHz
    ("clk25",          {"CLK_HZ": 25000000}),                                # Smallest accumulator clock range
    ("clk33",          {"CLK_HZ": 33333333}),                                # Accumulator, the Tang clock
    ("clk36",          {"CLK_HZ": 36000000}),                                # Counter
    ("clk100",         {"CLK_HZ": 100000000}),                               # Accumulator
    ("clk200",         {"CLK_HZ": 200000000}),                               # Fastest clock, widest timers
    ("open",           {"MDELEG_RST": "9'h000"}),                            # MDELEG open out of reset
    ("smode_sync_rst", {"MDELEG_RST": "9'h105", "ASYNC_RST_EN": 0}),         # Supervisor gates under sync reset
    ("addrw16",        {"ADDRW": 16}),                                       # Widest window
    ("tang",           {"CLK_HZ": 33333333, "ASYNC_RST_EN": 0}),             # Tang Console 138K build
    ("full_corner",    {"CLK_HZ": 25000000, "CTRL_EN": 1, "DIAG_EN": 1,      # Every option at the lowest accumulator clock
                        "ADDRW": 12, "MDELEG_RST": "9'h000", "ASYNC_RST_EN": 0}),
]
TOP_MODULE = "apb_usb_host"
