#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    sim_configs.py (apb_spi)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the apb_spi simulation test list and sweep set.
#
# Each SIM_CONFIGS entry is (label, defines, test_list):
#   - label     : config name used for log file names and the summary table
#   - defines   : dict of {DEFINE_NAME: value} -- forwarded to iverilog via -D
#   - test_list : ordered list of test names (file basenames in sim/rtl_sim/src/)
#
# The defines drive the testbench parameterization (tb_apb_spi.v):
#   SPI_TB_LANES_MAX, SPI_TB_CS_NR, SPI_TB_RX_EN, SPI_TB_POLL_EN,
#   SPI_TB_TX_FIFO_AW, SPI_TB_RX_FIFO_AW, SPI_TB_ADDRW, SPI_TB_MDELEG_RST
#   (decimal), SPI_TB_DBG_MASK (decimal), SPI_TB_ASYNC_RST_EN -> the DUT
#   parameters; SPI_TB_FREE_CLK=1 runs the bus clock ungated.
#
# Every test adapts to the parameters it runs under (lanes, selects, RX_EN,
# POLL_EN, the FIFO depths, MDELEG_RST, ...); a test that has nothing to check
# in a config prints SIMULATION SKIPPED (counted separately, never as a
# failure).
#
#   run_all          -> REGRESSION_CONFIGS; logs <test>.log for the default
#                       config, <test>--<label>.log otherwise
#   run_all -sweep   -> every SIM_CONFIGS entry (bin/run_sweep.py)
#   run_all -cov     -> every SIM_CONFIGS pair under Verilator (bin/runcov)
#   run <test> -config <label>  -> one test in one config
#----------------------------------------------------------------------------

DEFAULT_TESTS = [
    # Register file and bus
    "reset_values",
    "reg_rdwr",
    "mdeleg_access",
    "pclk_gating",
    # Serial clock, frames and lanes
    "clk_div",
    "clk_modes",
    "frame_bits",
    "lanes",
    "loopback",
    "rx_timing",
    # Chip selects and transactions
    "cs_timing",
    "cs_hold_gaps",
    "cs_none",
    "inact_gated",
    "config_latch",
    # Data path and control
    "rx_stall",
    "poll",
    "fifo_errors",
    "fifo_walk",
    "thresholds",
    "flush",
    "abort",
    "enable",
    "dbg_access",
    # Devices
    "sd_sequence",
    "flash_sequence",
    "reset_in_operation",
    "random_stress",
]

SIM_CONFIGS = [
    # (label,            defines,                                                     test_list)
    # RTL defaults: quad, one select, RX and POLL on, FIFOs 16, ADDRW=7, MDELEG_RST=9'h10F, async reset
    ("default",          {},                                                          DEFAULT_TESTS),
    # Synchronous reset: the reset generator requests the clock during reset
    ("sync_rst",         {"SPI_TB_ASYNC_RST_EN": 0},                                  DEFAULT_TESTS),
    # Lane builds
    ("single",           {"SPI_TB_LANES_MAX": 1},                                     DEFAULT_TESTS),
    ("dual",             {"SPI_TB_LANES_MAX": 2},                                     DEFAULT_TESTS),
    # Eight selects
    ("cs8",              {"SPI_TB_CS_NR": 8},                                         DEFAULT_TESTS),
    # Transmit only, no POLL
    ("tx_only",          {"SPI_TB_RX_EN": 0, "SPI_TB_POLL_EN": 0},                    DEFAULT_TESTS),
    ("no_poll",          {"SPI_TB_POLL_EN": 0},                                       DEFAULT_TESTS),
    # FIFO depth corners: 2 entries, 256, unequal
    ("fifo2",            {"SPI_TB_TX_FIFO_AW": 1, "SPI_TB_RX_FIFO_AW": 1},            DEFAULT_TESTS),
    ("fifo256",          {"SPI_TB_TX_FIFO_AW": 8, "SPI_TB_RX_FIFO_AW": 8},            DEFAULT_TESTS),
    ("fifo_mixed",       {"SPI_TB_TX_FIFO_AW": 3, "SPI_TB_RX_FIFO_AW": 6,
                          "SPI_TB_ADDRW": 12},                                        DEFAULT_TESTS),
    # MDELEG open out of reset (9'h000: User / User, silent drop)
    ("open",             {"SPI_TB_MDELEG_RST": 0},                                    DEFAULT_TESTS),
    # Debugger mask: none, a non-default mask
    ("dbg_none",         {"SPI_TB_DBG_MASK": 0},                                      DEFAULT_TESTS),
    ("dbg_mask10",       {"SPI_TB_DBG_MASK": 10},                                     DEFAULT_TESTS),
    # Bus clock never gated
    ("free_clk",         {"SPI_TB_FREE_CLK": 1},                                      DEFAULT_TESTS),
    # Window width maximum, sync reset, Supervisor gates, three selects
    ("mixed",            {"SPI_TB_ADDRW": 16, "SPI_TB_ASYNC_RST_EN": 0,
                          "SPI_TB_MDELEG_RST": 261, "SPI_TB_TX_FIFO_AW": 2,
                          "SPI_TB_CS_NR": 3},                                         DEFAULT_TESTS),
    # The SD-card build: single lane, two selects, sync reset
    ("sd_build",         {"SPI_TB_LANES_MAX": 1, "SPI_TB_CS_NR": 2,
                          "SPI_TB_ASYNC_RST_EN": 0, "SPI_TB_RX_FIFO_AW": 6},          DEFAULT_TESTS),
    # Transmit-only dual corner
    ("tx_only_corner",   {"SPI_TB_LANES_MAX": 2, "SPI_TB_RX_EN": 0, "SPI_TB_POLL_EN": 0,
                          "SPI_TB_TX_FIFO_AW": 1, "SPI_TB_CS_NR": 3, "SPI_TB_MDELEG_RST": 0}, DEFAULT_TESTS),
]

# Configs run by a plain `run_all` (the regression); `run_all -sweep` runs all.
REGRESSION_CONFIGS = ["default", "sync_rst", "single", "dual", "cs8", "tx_only", "fifo2"]

TB_TOP = "tb_apb_spi"

# Functional coverage gate of the sweep: every bin must be hit in at least one
# (config, test) run (the tb's cover_report prints "COVERAGE HIT: <bin>")
MANDATORY_COVER_BINS = [
    "write", "read", "back_to_back", "pslverr", "partial_strobe", "penable_without_psel",
    "silent_drop", "smode_admitted", "umode_admitted", "pclk_gated", "reset_in_operation",
    "mode0", "mode1", "mode2", "mode3",
    "tx_single", "rx_single", "dummy_single", "poll_single",
    "tx_dual", "rx_dual", "dummy_dual", "poll_dual",
    "tx_quad", "rx_quad", "dummy_quad", "poll_quad",
    "frame_1bit", "frame_32bit", "lsb_first", "bswap", "lsb_first_bswap",
    "cs_hold_continued", "cs_hold_switched", "cs_hold_to_none", "cs_none", "cs_active_high",
    "cs_held_clock_gated", "stall", "stall_mid_entry", "capture_after_release",
    "rx_dly_0", "rx_dly_15", "rx_dly_ge_2half",
    "poll_first_frame", "poll_mid", "poll_last_frame", "poll_timeout", "poll_pause",
    "xfer_err", "tx_ovf", "rx_udf", "sparse_txdata", "w1c_event_race", "done",
    "abort_shift", "abort_pause", "abort_wait", "abort_setup",
    "en_cleared_busy", "cpol_write_held", "resume", "three_wire", "io23_released",
    "loopback", "dbg_peek", "dbg_pop", "tx_low_irq", "rx_high_irq",
    "tx_flush", "rx_flush", "tx_full", "rx_full", "cs_timing_16", "inact_enforced",
]


def config(label):
    """Return (label, defines, tests) for a config label."""
    for entry in SIM_CONFIGS:
        if entry[0] == label:
            return entry
    raise KeyError(label)


def defines_args(label):
    """iverilog -D arguments for a config label, as one string."""
    return " ".join("-D %s=%s" % kv for kv in sorted(config(label)[1].items()))


if __name__ == "__main__":
    import sys
    # Used by run / run_all:
    #   sim_configs.py defines <label>      -> "-D K=V ..."
    #   sim_configs.py tests <label>        -> "t1 t2 ..."
    #   sim_configs.py regression           -> "label1 label2 ..."
    #   sim_configs.py labels               -> every label
    if len(sys.argv) >= 2 and sys.argv[1] == "defines":
        print(defines_args(sys.argv[2]))
    elif len(sys.argv) >= 2 and sys.argv[1] == "tests":
        print(" ".join(config(sys.argv[2])[2]))
    elif len(sys.argv) >= 2 and sys.argv[1] == "regression":
        print(" ".join(REGRESSION_CONFIGS))
    elif len(sys.argv) >= 2 and sys.argv[1] == "labels":
        print(" ".join(e[0] for e in SIM_CONFIGS))
    else:
        sys.exit("usage: sim_configs.py defines|tests <label> | regression | labels")
