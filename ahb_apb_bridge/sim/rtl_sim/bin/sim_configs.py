#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    sim_configs.py (ahb_apb_bridge)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the ahb_apb_bridge simulation sweep set.
#
# Each entry is (label, defines, test_list):
#   - label     : config name used for log directories and the summary table
#   - defines   : dict of {DEFINE_NAME: value} -- forwarded to iverilog via -D
#   - test_list : ordered list of test names (file basenames in sim/rtl_sim/src/)
#
# The bench (tb_ahb_apb_bridge.v) builds one of four completer maps from
# BRG_CFG: 0 three completers with a gap (0x000 256 B, 0x400 1 KB, 0x800
# 16 B; 0x100-0x3FF and 0x810-0xFFF unmapped), 1 a single completer owning
# the whole 256-byte window, 2 sixteen 4-KB completers, 3 the map of 0 with a
# one-word completer at 0x800 (SLV_AW = 2, no PSLVERR word); BRG_ASYNC_RST_EN
# selects the reset style, on every map; BRG_CGATE=1 clocks the bridge and
# the completers through a latch-based clock gate enabled by hclk_en_o (one
# ICG for the bridge and its completers), in both reset styles.
#----------------------------------------------------------------------------

DEFAULT_TESTS = [
    "simple_rdwr",
    "wait_states",
    "strobes",
    "slverr",
    "unmapped",
    "oversize",
    "misaligned",
    "pipelined",
    "busy_idle",
    "prot_smode",
    "hsel_idle",
    "reset_mid_transfer",
    "clock_request",
    "random_traffic",
    "data_walk",
    "bus_stall",
]

SIM_CONFIGS = [
    ("default",    {},                                       DEFAULT_TESTS),
    ("one",        {"BRG_CFG": 1},                           DEFAULT_TESTS),
    ("s16",        {"BRG_CFG": 2},                           DEFAULT_TESTS),
    ("sync_rst",   {"BRG_ASYNC_RST_EN": 0},                  DEFAULT_TESTS),
    ("one_sync",   {"BRG_CFG": 1, "BRG_ASYNC_RST_EN": 0},    DEFAULT_TESTS),
    ("s16_sync",   {"BRG_CFG": 2, "BRG_ASYNC_RST_EN": 0},    DEFAULT_TESTS),
    ("word",       {"BRG_CFG": 3},                           DEFAULT_TESTS),
    ("word_sync",  {"BRG_CFG": 3, "BRG_ASYNC_RST_EN": 0},    DEFAULT_TESTS),
    ("cgate",      {"BRG_CGATE": 1},                         DEFAULT_TESTS),
    ("cgate_sync", {"BRG_CGATE": 1, "BRG_ASYNC_RST_EN": 0},  DEFAULT_TESTS),
]

# Functional coverage gate of the sweep: every bin must be hit in at least one
# (config, test) run (the tb's cover_report prints "COVERAGE HIT: <bin>")
MANDATORY_COVER_BINS = [
    "read", "write", "apb_wait", "pslverr", "unmapped", "size_err",
    "back_to_back", "accept_after_error", "partial_strobe",
    "htrans_busy", "htrans_idle_selected", "hsel_low",
    "hclk_en_hi", "hclk_en_lo", "reset_in_transfer", "bus_stall",
    "misaligned", "clock_gated", "pready_outside_access", "pslverr_in_wait",
]
