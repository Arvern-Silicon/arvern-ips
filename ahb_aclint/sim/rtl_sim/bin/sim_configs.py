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
    "mtimer_zicntr_wr_coherency",
    "mtimer_wake",
    "mtimer_cmp_boundary",
    "mtimer_mtip_mask",
    "mtimer_cmp_torn_write",
    "mtimer_cmp_wrap",
    "mtimer_mtime_write",
    "mtimer_warm_reset",
    "mtimer_load_oneshot",
    "mtimer_half_write",
    "mtimer_cmp_sleep_hold",
    "mtimer_lf_duty",
    "mtimer_deep_sleep",
    "mtimer_tick_stress",
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
    # coverage-driven review follow-up
    "mtimer_data_patterns",
    "mtimer_mtime_load_mtip",
    "mtimer_scan_mode",
    "ahb_reset_midtransfer",
    "ahb_corner_trio",
    "mtimer_deep_sleep_zero_edge",
    "mtimer_mtime_write_tick_walk",
]

# Tests that exercise the hclk<->clk_lf boundary, and are therefore the ones
# worth repeating at a realistic (slow) LF ratio.
MTIMER_CDC_TESTS = [
    "mtimer_mtime_write",
    "mtimer_warm_reset",
    "mtimer_load_oneshot",
    "mtimer_half_write",
    "mtimer_cmp_sleep_hold",
    "mtimer_deep_sleep",
    "mtimer_tick_stress",
    "mtimer_cmp_writeback",
    "mtimer_cmp_stall",
    "mtimer_atomic_read",
    "mtimer_cmp_boundary",
    "mtimer_mtip_mask",
    "mtimer_cmp_torn_write",
    "mtimer_cmp_wrap",
    "mtimer_zicntr_time",
    "mtimer_wake",
    "mtimer_data_patterns",
    "mtimer_mtime_load_mtip",
    "mtimer_deep_sleep_zero_edge",
]
MULTIHART_TESTS = [
    "mswi_multihart",
    "mtimer_multihart",
    "sswi_multihart",
    "mtimer_hart_sweep",
]

SIM_CONFIGS = [
    # (label,            defines,                                            test_list)
    # The default sits AT the recommended clk_lf:hclk ratio (R = 10), the ratio
    # that keeps both clk_lf phases >= 2 hclk periods even at a 20/80 duty cycle.
    # That is the tightest end for the tick detector -- a fast clk_lf is the
    # dangerous corner, not a slow one -- so it is the ratio worth running every
    # test at.
    ("default",          {},                                                 DEFAULT_TESTS),
    ("nh2",              {"ACLINT_NUM_HARTS": 2},                            ["mswi_basic", "unmapped_access"] + MULTIHART_TESTS),
    ("nh16",             {"ACLINT_NUM_HARTS": 16},                           ["mswi_basic", "unmapped_access", "mtimer_hart_hi"] + MULTIHART_TESTS),
    ("su0",              {"ACLINT_SU_MODE_EN": 0},                           ["mswi_basic", "mtimer_cmp_writeback", "mtimer_wake", "mtimer_zicntr_time", "unmapped_access", "su_disabled"]),
    ("priv_off",         {"ACLINT_PRIV_CHECK_EN": 0},                        ["priv_check_off", "mswi_basic", "unmapped_access", "ahb_subword"]),
    ("sync_rst",         {"ACLINT_ASYNC_RST_EN": 0},                         DEFAULT_TESTS),
    # --- CDC clock-ratio stress -------------------------------------------
    # The clk_lf:hclk ratio is a real CDC axis. The configs above all run the
    # default 10:1 (LF half-period 250 ns vs a 20 MHz free_clk), which is
    # orders of magnitude away from the intended 32 kHz-crystal operating
    # point -- and a guard sized in hclk cycles can be correct at 10:1 while
    # leaving a (T_lf - guard) hole at 3000:1. Run the timer tests at two
    # slower ratios (40:1, 400:1) as well; keep the fast one, it stresses the
    # opposite corner (same-edge and back-to-back write races).
    ("slow_lf40",        {"ACLINT_LF_HALF_PERIOD": 1000},                    MTIMER_CDC_TESTS),
    ("slow_lf400",       {"ACLINT_LF_HALF_PERIOD": 10000},                   MTIMER_CDC_TESTS),
    # Synchronous reset AT a slow ratio. sync_rst alone runs only at 10:1,
    # where the clock-stop corner is compressed into a handful of hclk cycles; a
    # sync-reset flop that never reaches its reset value because the oscillator
    # stopped without leaving it an edge is only visible with a real LF period to
    # sleep through. This is the configuration mtimer_deep_sleep's post-wake
    # stall check is there to defend.
    ("sync_rst_slow",    {"ACLINT_ASYNC_RST_EN": 0, "ACLINT_LF_HALF_PERIOD": 10000}, MTIMER_CDC_TESTS),
    # --- synchronous timebase (LF_SYNC_EN=1) -------------------------------
    # No second clock at all: clk_lf/resetn_lf are tied off and MTIME is paced by
    # a one-cycle clk_lf_re pulse on hclk_aon. This is the FPGA configuration and
    # it removes both SDC max-delay exceptions, so it must be regressed as a
    # first-class mode rather than assumed equivalent. mtimer_warm_reset is
    # included deliberately: with no LF domain there is nothing to preserve
    # across a warm reset, and that difference should be visible if it regresses.
    ("lf_sync",          {"ACLINT_LF_SYNC_EN": 1},                           DEFAULT_TESTS),
    # Synchronous timebase at the two slow ratios as well: the tick detector is
    # shared with the asynchronous mode, so the ratio axis applies to both.
    ("lf_sync_slow",     {"ACLINT_LF_SYNC_EN": 1, "ACLINT_LF_HALF_PERIOD": 10000}, MTIMER_CDC_TESTS),
    # Synchronous timebase AND synchronous reset -- the natural FPGA persona, and
    # the one combination neither axis covers on its own. Both reset styles are
    # meant to be behaviourally identical, so the mode that removes the SDC
    # exceptions has to be regressed in both of them.
    ("lf_sync_rst",      {"ACLINT_LF_SYNC_EN": 1, "ACLINT_ASYNC_RST_EN": 0},     DEFAULT_TESTS),
]

TB_TOP = "tb_ahb_aclint"

# Functional-coverage gate (homegrown, see bench/verilog/cover_monitor.v).
# Each test emits "COVERAGE HIT: <bin>" lines; run_sweep.py unions them across
# EVERY (config, test) run and FAILS the sweep if any bin below was never hit
# in any config. This is the suite-level check that makes an unexercised FSM
# state / interface visible. A bin only needs to be hit by
# ONE config to count, so config-specific bins (e.g. mtip_top_hart at nh16,
# hresp_err under PRIV_CHECK_EN=1) are fine.
MANDATORY_COVER_BINS = [
    # LF observation: the tick fires, and the mirror is seen both trustworthy and
    # invalidated. "mirror_stale" is the one that proves the deep-sleep staleness
    # path is real rather than dead code.
    "lf_tick", "mirror_valid", "mirror_stale", "time_req", "time_gnt",
    # Write shadows + the LF-side load. "load_ack" proves an MTIME write actually
    # reached the counter through the open-loop request.
    "cmp_wr", "mtime_wr", "load_ack",
    # Clock-gate advisory exercised in both directions
    "hclk_en_hi", "hclk_en_lo",
    # Interrupt outputs, including the LF wake line
    "irq_msw", "irq_mtip", "irq_ssw", "wake_lf",
    # AHB protocol corners
    "hresp_err", "pipelined", "wait_state", "htrans_seq", "htrans_busy", "subword",
    # High-index per-hart muxing (nh16)
    "mtip_top_hart",
    # The only wait state in the block (MTIME read into an invalid mirror)
    "mtime_rd_stall",
]

# Bins that NO single config can hit, because they need a parameterization the
# default build does not have. `run_all` (single default config) reports these as
# expected-absent instead of failing on them; `run_all -sweep` still requires
# every mandatory bin, since it runs the configs that reach them.
SWEEP_ONLY_COVER_BINS = [
    "mtip_top_hart",   # needs NUM_HARTS=16 (config nh16)
]
