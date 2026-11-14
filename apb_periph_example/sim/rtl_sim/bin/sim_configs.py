#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    sim_configs.py (apb_periph_example)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the apb_periph_example simulation sweep set.
#
# Each entry is (label, defines, test_list):
#   - label     : config name used for log directories and the summary table
#   - defines   : dict of {DEFINE_NAME: value} -- forwarded to iverilog via -D
#   - test_list : ordered list of test names (file basenames in sim/rtl_sim/src/)
#
# The bench (tb_apb_periph_example.v) maps PER_ADDRW onto ADDRW and
# PER_ASYNC_RST_EN onto ASYNC_RST_EN and PER_MDELEG_RST (an integer) onto
# MDELEG_RST. The "open" build resets MDELEG to 9'h001: supervisor writes,
# user reads, refusals ignored; every field differs from the default 9'h10F.
# "free_clk" runs pclk ungated (PER_FREE_CLK), so a register load outside a
# selected transfer would land and fail the bench's register check.
#----------------------------------------------------------------------------

DEFAULT_TESTS = [
    "simple_rdwr",
    "rw_data_walk",
    "ro_input_walk",
    "strobes",
    "mdeleg_lanes",
    "mdeleg_access",
    "mdeleg_reset",
    "priv_levels",
    "unmapped",
    "pprot_ignored",
    "back_to_back",
    "setup_commit",
    "reset_mid_transfer",
    "clock_request",
    "random_traffic",
]

SIM_CONFIGS = [
    ("default",    {},                                       DEFAULT_TESTS),
    ("addrw8",     {"PER_ADDRW": 8},                         DEFAULT_TESTS),
    ("sync_rst",   {"PER_ASYNC_RST_EN": 0},                  DEFAULT_TESTS),
    ("open",       {"PER_MDELEG_RST": 1},                    DEFAULT_TESTS),
    ("free_clk",   {"PER_FREE_CLK": 1},                      DEFAULT_TESTS),
]

# Functional coverage gate of the sweep: every bin must be hit in at least one
# (config, test) run (the tb's cover_report prints "COVERAGE HIT: <bin>")
MANDATORY_COVER_BINS = [
    "read", "write", "pslverr_read", "pslverr_write", "denied_ignored",
    "back_to_back", "partial_strobe", "zero_strobe", "mdeleg_write",
    "user_mode", "supervisor_mode", "machine_mode", "pprot_upper",
    "unmapped", "reset_in_transfer", "pclk_en_lo", "open_reset",
    "foreign_access", "user_smode_hi", "read_strobe",
]
