#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    rtl_configs.py (apb_gpio)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the apb_gpio RTL parameterization sweep set.
#
# Consumed by lint/vc_static/run_vclint and synthesis/synopsys/run_syn
# (-rtl_config / -rtl_sweep) through bin/gen_rtl_params.py. The simulation
# regression (sim/rtl_sim/run/run_all) runs the same builds from its own list;
# a new config goes in both.
#
# Each entry is (label, {PARAM: value}). Unspecified parameters take their
# RTL default. The label is used to name log files and the summary column.
#
# Coverage rationale, one factor at a time around the defaults (GPIO_NR=32,
# SYNC_EN=1, MDELEG_RST=9'h10F, ASYNC_RST_EN=1, ADDRW=7) plus one corner:
#   ASYNC_RST_EN  0 is the ONLY setting that builds the arv_ipdff /
#                 arv_synchronizer sync-reset branches and the reset term of
#                 the input-path clock gate (G_RST_CLK_REQ); rules.tcl
#                 enforces the opposite reset rule for it.
#   SYNC_EN       gates the per-pin synchroniser generate and sets the depth
#                 of the per-pin flush pipeline (G_SYNC / G_NO_SYNC).
#   MDELEG_RST    only the reset values of the three MDELEG flops: 9'h000
#                 resets every bit to 0 (the opposite of the default's 1s),
#                 9'h105 a Supervisor field, whose two bits mix a set and a
#                 reset flop (the waived CODING_TREE_SETRST_ORIG case).
#   GPIO_NR       sizes every pin-field register and selects the zero-padding
#                 generate (G_PIN_PAD for < 32, G_NO_PIN_PAD for 32):
#                   32  full word, no padding (default)
#                   31  partial top byte lane, padding branch
#                    8  exactly one byte lane
#                    1  a single bit: the narrowest legal vectors
#   ADDRW         the default 7 is the minimum window; 8 checks that the
#                 decoder compares the full word address (no aliasing).
#----------------------------------------------------------------------------

CONFIGS = [
    # label            parameter overrides
    ("default",        {}),                                                  # RTL defaults
    ("sync_rst",       {"ASYNC_RST_EN": 0}),                                 # Sync reset: arv_ipdff/arv_synchronizer sync branches, ICG reset term
    ("no_sync",        {"SYNC_EN": 0}),                                      # gpio_i registered once, no synchroniser
    ("no_cgate",       {"INP_CGATE_EN": 0}),                                 # No input-path clock gate (FPGA)
    ("open",           {"MDELEG_RST": "9'h000"}),                            # MDELEG open out of reset: every MDELEG bit resets to 0
    ("smode_sync_rst", {"MDELEG_RST": "9'h105", "ASYNC_RST_EN": 0}),         # Supervisor gates (mixed set/reset field) under sync reset
    ("gpio31",         {"GPIO_NR": 31}),                                     # Partial top lane, padding branch
    ("gpio8",          {"GPIO_NR": 8}),                                      # One full byte lane
    ("gpio1",          {"GPIO_NR": 1}),                                      # Single pin
    ("gpio1_corner",   {"GPIO_NR": 1, "SYNC_EN": 0,                          # Every non-default branch at once
                        "MDELEG_RST": "9'h000", "ASYNC_RST_EN": 0, "INP_CGATE_EN": 0}),
    ("addrw8",         {"ADDRW": 8}),                                        # Window above the minimum
    ("alt1",           {"ALT_NR": 1}),                                       # ALT_EN only
    ("alt2",           {"ALT_NR": 2}),                                       # ALT_EN + ALT_SEL0
    ("alt3",           {"ALT_NR": 3}),                                       # Both select registers, out-of-range number 3
    ("alt4",           {"ALT_NR": 4}),                                       # Every function
    ("alt4_gpio1",     {"ALT_NR": 4, "GPIO_NR": 1, "ASYNC_RST_EN": 0}),      # Every function, single pin, sync reset
]
TOP_MODULE = "apb_gpio"
