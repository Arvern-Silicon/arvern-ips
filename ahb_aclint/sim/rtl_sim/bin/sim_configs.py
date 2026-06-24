#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    sim_configs.py (ahb_aclint)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the ahb_aclint simulation sweep set.
#
# Each entry is (label, defines, test_list):
#   - label     : config name used for log directories and the summary table
#   - defines   : dict of {DEFINE_NAME: value} -- forwarded to iverilog via -D
#   - test_list : ordered list of test names (file basenames in sim/rtl_sim/src/)
#
# Defines drive the testbench parameterization (see tb_ahb_aclint.v: the TB
# `\`define`s control NUM_HARTS / SU_MODE_EN / SETSSIP_EN at elaboration).
# A test compatible with a given config appears in that config's test_list;
# incompatible tests (e.g. sswi_basic at SU_MODE_EN=0) are omitted.
#----------------------------------------------------------------------------

DEFAULT_TESTS = [
    "mswi_basic",
    "mtimer_cmp_writeback",
    "mtimer_cmp_stall",
    "mtimer_atomic_read",
    "mtimer_zicntr_time",
    "mtimer_wake",
    "mtimer_cmp_boundary",
    "mtimer_mtip_mask",
    "sswi_basic",
    "unmapped_access",
    "priv_check",
    "reset_values",
    # AHB-Lite protocol corners
    "ahb_wait_states",
    "ahb_pipelined",
    "ahb_subword",
    "ahb_htrans_seq_busy",
    "ahb_hsel_deassert",
    "ahb_error_p2",
]

MULTIHART_TESTS = [
    "mswi_multihart",
    "mtimer_multihart",
    "sswi_multihart",
]

SIM_CONFIGS = [
    # (label,            defines,                                            test_list)
    ("default",          {},                                                 DEFAULT_TESTS),
    ("nh2",              {"ACLINT_NUM_HARTS": 2},                            ["mswi_basic", "unmapped_access"] + MULTIHART_TESTS),
    ("nh16",             {"ACLINT_NUM_HARTS": 16},                           ["mswi_basic", "unmapped_access", "mtimer_hart_hi"] + MULTIHART_TESTS),
    ("su0",              {"ACLINT_SU_MODE_EN": 0},                           ["mswi_basic", "mtimer_cmp_writeback", "mtimer_wake", "mtimer_zicntr_time", "unmapped_access", "su_disabled"]),
    ("priv_off",         {"ACLINT_PRIV_CHECK_EN": 0},                        ["priv_check_off", "mswi_basic", "unmapped_access", "ahb_subword"]),
    ("sync_rst",         {"ACLINT_ASYNC_RST_EN": 0},                         DEFAULT_TESTS),
]

TB_TOP = "tb_ahb_aclint"

# Functional-coverage gate (homegrown, see bench/verilog/cover_monitor.v).
# Each test emits "COVERAGE HIT: <bin>" lines; run_sweep.py unions them across
# EVERY (config, test) run and FAILS the sweep if any bin below was never hit
# in any config. This is the suite-level check that makes an unexercised FSM
# state / interface visible -- the blind spot that originally hid the
# mtimer_active_o (time_gnt_r) clock-gate bug. A bin only needs to be hit by
# ONE config to count, so config-specific bins (e.g. mtip_top_hart at nh16,
# hresp_err under PRIV_CHECK_EN=1) are fine.
MANDATORY_COVER_BINS = [
    # Zicntr time-read path + arbitration FSM (the escaped-bug neighbourhood)
    "fsm_idle", "fsm_ahb_pend", "fsm_time_pend", "time_req", "time_gnt",
    # MTIMECMP write CDC + resulting AHB stall
    "wlo_busy", "whi_busy", "wr_stall",
    # Clock-gate advisory exercised in both directions
    "hclk_en_hi", "hclk_en_lo",
    # Interrupt outputs (incl. the formerly-dangling wake line)
    "irq_msw", "irq_mtip", "irq_ssw", "wake_lf",
    # AHB protocol corners that were never stimulated
    "hresp_err", "pipelined", "wait_state", "htrans_seq", "htrans_busy", "subword",
    # High-index per-hart muxing (nh16)
    "mtip_top_hart",
    # MTIP write-busy suppression mask actually engaged
    "mtip_masked",
]
