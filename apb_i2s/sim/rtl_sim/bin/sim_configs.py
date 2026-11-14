#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    sim_configs.py (apb_i2s)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the apb_i2s simulation test list and sweep set.
#
# Each SIM_CONFIGS entry is (label, defines, test_list):
#   - label     : config name used for log file names and the summary table
#   - defines   : dict of {DEFINE_NAME: value} -- forwarded to iverilog via -D
#   - test_list : ordered list of test names (file basenames in sim/rtl_sim/src/)
#
# The defines drive the testbench parameterization (tb_apb_i2s.v):
#   I2S_TB_TX_EN, I2S_TB_RX_EN, I2S_TB_TX_FIFO_AW, I2S_TB_RX_FIFO_AW,
#   I2S_TB_ADDRW, I2S_TB_MDELEG_RST (decimal), I2S_TB_DBG_MASK (decimal),
#   I2S_TB_ASYNC_RST_EN -> the DUT parameters.
#
# Every test adapts to the parameters it runs under (TX_EN, RX_EN, the FIFO
# depths, MDELEG_RST, ...); a test that has nothing to check in a config
# prints SIMULATION SKIPPED (counted separately, never as a failure).
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
    # Clock generator and formats
    "clk_ratios",
    "clk_stop",
    "stop_timing",
    "tx_formats",
    "rx_formats",
    "loopback",
    "rx_timing",
    # Data path
    "tx_mono",
    "rx_mono",
    "tx_mono_race",
    "rx_stop_mono",
    "tx_underrun",
    "rx_overrun",
    "fifo_errors",
    "thresholds",
    "flush",
    "fifo_walk",
    "stream_start_stop",
    "dbg_access",
    "reset_in_operation",
    "random_stress",
]

SIM_CONFIGS = [
    # (label,            defines,                                                     test_list)
    # RTL defaults: TX/RX on, FIFOs 32 words, ADDRW=7, MDELEG_RST=9'h10F, DBG mask 8, async reset
    ("default",          {},                                                          DEFAULT_TESTS),
    # MDELEG open out of reset (9'h000: User / User, silent drop)
    ("open",             {"I2S_TB_MDELEG_RST": 0},                                    DEFAULT_TESTS),
    # Synchronous reset: the reset generator requests the clock during reset
    ("sync_rst",         {"I2S_TB_ASYNC_RST_EN": 0},                                  DEFAULT_TESTS),
    # One direction only
    ("tx_only",          {"I2S_TB_RX_EN": 0},                                         DEFAULT_TESTS),
    ("rx_only",          {"I2S_TB_TX_EN": 0},                                         DEFAULT_TESTS),
    # FIFO depth corners: 2 words, 256 words, unequal
    ("fifo2",            {"I2S_TB_TX_FIFO_AW": 1, "I2S_TB_RX_FIFO_AW": 1},            DEFAULT_TESTS),
    ("fifo256",          {"I2S_TB_TX_FIFO_AW": 8, "I2S_TB_RX_FIFO_AW": 8},            DEFAULT_TESTS),
    ("fifo_mixed",       {"I2S_TB_TX_FIFO_AW": 3, "I2S_TB_RX_FIFO_AW": 6,
                          "I2S_TB_ADDRW": 12},                                        DEFAULT_TESTS),
    # Debugger mask: none (every access is the core's), a non-default mask that
    # still tells the debugger (4'h9) from the hart (4'h1)
    ("dbg_none",         {"I2S_TB_DBG_MASK": 0},                                      DEFAULT_TESTS),
    ("dbg_mask10",       {"I2S_TB_DBG_MASK": 10},                                     DEFAULT_TESTS),
    # Window width maximum, sync reset, Supervisor gates
    ("mixed",            {"I2S_TB_ADDRW": 16, "I2S_TB_ASYNC_RST_EN": 0,
                          "I2S_TB_MDELEG_RST": 261, "I2S_TB_TX_FIFO_AW": 2},          DEFAULT_TESTS),
    ("tx_only_sync",     {"I2S_TB_RX_EN": 0, "I2S_TB_ASYNC_RST_EN": 0,
                          "I2S_TB_TX_FIFO_AW": 1},                                    DEFAULT_TESTS),
    ("rx_only_open",     {"I2S_TB_TX_EN": 0, "I2S_TB_MDELEG_RST": 0,
                          "I2S_TB_RX_FIFO_AW": 8},                                    DEFAULT_TESTS),
]

# Configs run by a plain `run_all` (the regression); `run_all -sweep` runs all.
REGRESSION_CONFIGS = ["default", "open", "sync_rst", "tx_only", "rx_only", "fifo2"]

TB_TOP = "tb_apb_i2s"

# Functional coverage gate of the sweep: every bin must be hit in at least one
# (config, test) run (the tb's cover_report prints "COVERAGE HIT: <bin>")
MANDATORY_COVER_BINS = [
    "write", "read", "back_to_back", "pslverr", "partial_strobe", "penable_without_psel",
    "silent_drop", "smode_admitted", "umode_admitted", "pclk_gated", "reset_in_transfer",
    "fmt_i2s", "fmt_lj", "fmt_rj", "fmt_dsp_a", "fmt_dsp_b", "bclk_inv", "slot16",
    "ratio_256", "ratio_384", "ratio_512", "ratio_768", "ratio_1024", "mdiv_gt_1", "mclk_off",
    "tx_mono", "rx_mono_left", "rx_mono_right", "rx_mono_avg",
    "tx_under", "rx_over", "tx_ovf", "rx_udf", "tx_low_irq", "rx_high_irq", "sticky_irq",
    "dbg_peek", "dbg_pop", "loopback", "tx_flush", "rx_flush", "tx_full", "rx_full",
    "cfg_locked", "w1c_event_race", "stop_delayed", "tail_capture", "mono_drop_at_take",
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
