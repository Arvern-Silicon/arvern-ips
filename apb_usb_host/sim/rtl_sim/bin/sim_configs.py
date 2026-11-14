#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    sim_configs.py (apb_usb_host)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the apb_usb_host simulation test list and sweep set.
#
# Each SIM_CONFIGS entry is (label, defines, test_list):
#   - label     : config name used for log file names and the summary table
#   - defines   : dict of {DEFINE_NAME: value} -- forwarded to iverilog via -D
#   - test_list : ordered list of test names (file basenames in sim/rtl_sim/src/)
#
# The defines drive the testbench parameterization (tb_apb_usb_host.v):
#   USB_TB_CLK_HZ, USB_TB_CTRL_EN, USB_TB_DIAG_EN, USB_TB_ADDRW,
#   USB_TB_MDELEG_RST (decimal), USB_TB_ASYNC_RST_EN -> the DUT parameters;
#   USB_TB_FREE_CLK=1 runs the bus clock ungated.
#
# Every test adapts to the parameters it runs under (CLK_HZ, CTRL_EN, DIAG_EN,
# ADDRW, MDELEG_RST, ...); a test that has nothing to check
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
    "irq_w1c",
    "reset_in_operation",
    "diag_counters",
    # Port state machine
    "attach_debounce",
    "fs_device",
    "ctrl_en_states",
    "ctrl_en_states2",
    "restart_cmd",
    "restart_cmd2",
    "detach_attach",
    "detach_attach2",
    "keepalive_idle",
    # Enumeration
    "enum_kbd",
    "enum_profiles",
    "enum_unsupported",
    "enum_malformed",
    "enum_fail_steps",
    "enum_fail_steps2",
    "enum_attempts",
    "enum_progress",
    "enum_optional",
    "enum_lost_ack",
    # Polling, transactions, report buffer
    "poll_rate",
    "poll_errors",
    "poll_dead_device",
    "poll_toggle",
    "report_buffer",
    "bus_busy",
    "dev_timing",
    "dev_timing2",
    # Software control transfers
    "xfer_in",
    "xfer_out",
    "xfer_errors",
    "xfer_abort",
]

SIM_CONFIGS = [
    # (label,            defines,                                                     test_list)
    # RTL defaults: 48 MHz (counter bit clock), no options, ADDRW=8, MDELEG_RST=9'h10F, async reset
    ("default",          {},                                                          DEFAULT_TESTS),
    # Synchronous reset: the reset generator requests the clock during reset
    ("sync_rst",         {"USB_TB_ASYNC_RST_EN": 0},                                  DEFAULT_TESTS),
    # Options
    ("ctrl",             {"USB_TB_CTRL_EN": 1},                                       DEFAULT_TESTS),
    ("diag",             {"USB_TB_DIAG_EN": 1},                                       DEFAULT_TESTS),
    ("full",             {"USB_TB_CTRL_EN": 1, "USB_TB_DIAG_EN": 1},                  DEFAULT_TESTS),
    # Clocks: counter (multiples of 1.5 MHz) and phase accumulator
    ("clk12",            {"USB_TB_CLK_HZ": 12000000},                                 DEFAULT_TESTS),
    ("clk13m5",          {"USB_TB_CLK_HZ": 13500000},                                 DEFAULT_TESTS),
    ("clk25",            {"USB_TB_CLK_HZ": 25000000},                                 DEFAULT_TESTS),
    ("clk33",            {"USB_TB_CLK_HZ": 33333333},                                 DEFAULT_TESTS),
    ("clk36",            {"USB_TB_CLK_HZ": 36000000},                                 DEFAULT_TESTS),
    ("clk100",           {"USB_TB_CLK_HZ": 100000000},                                DEFAULT_TESTS),
    ("clk200",           {"USB_TB_CLK_HZ": 200000000},                                DEFAULT_TESTS),
    # MDELEG open out of reset (9'h000: User / User, silent drop)
    ("open",             {"USB_TB_MDELEG_RST": 0},                                    DEFAULT_TESTS),
    # Bus clock never gated
    ("free_clk",         {"USB_TB_FREE_CLK": 1},                                      DEFAULT_TESTS),
    # Window width maximum, sync reset, Supervisor gates
    ("mixed",            {"USB_TB_ADDRW": 16, "USB_TB_ASYNC_RST_EN": 0,
                          "USB_TB_MDELEG_RST": 261},                                  DEFAULT_TESTS),
    # The Tang Console 138K build
    ("tang",             {"USB_TB_CLK_HZ": 33333333, "USB_TB_ASYNC_RST_EN": 0},       DEFAULT_TESTS),
    # Every option at the lowest accumulator clock
    ("full_corner",      {"USB_TB_CLK_HZ": 25000000, "USB_TB_CTRL_EN": 1, "USB_TB_DIAG_EN": 1,
                          "USB_TB_ADDRW": 12, "USB_TB_MDELEG_RST": 0,
                          "USB_TB_ASYNC_RST_EN": 0},                                  DEFAULT_TESTS),
]

# Configs run by a plain `run_all` (the regression); `run_all -sweep` runs all.
REGRESSION_CONFIGS = ["default", "sync_rst", "full", "clk12", "clk33"]

TB_TOP = "tb_apb_usb_host"

# Functional coverage gate of the sweep: every bin must be hit in at least one
# (config, test) run (the tb's cover_report prints "COVERAGE HIT: <bin>")
MANDATORY_COVER_BINS = [
    "write", "read", "back_to_back", "pslverr", "partial_strobe", "penable_without_psel",
    "silent_drop", "smode_admitted", "umode_admitted", "pclk_gated", "reset_in_operation",
    "state_off", "state_detached", "state_debounce", "state_reset", "state_recovery",
    "state_enum", "state_run", "state_backoff", "state_failed", "state_unsupported",
    "state_fs_detected",
    "err_1", "err_2", "err_3", "err_4", "err_5", "err_6", "err_7", "err_8", "err_9",
    "irq_report", "irq_ready", "irq_detach", "irq_fail", "irq_xfer_pkt", "irq_xfer_done", "irq_state",
    "irq_out_report", "irq_out_ready", "irq_out_detach", "irq_out_fail", "irq_out_xfer_pkt",
    "irq_out_xfer_done", "irq_out_state",
    "xres_0", "xres_1", "xres_2", "xres_3", "xres_4", "xres_5",
    "attempt_0", "attempt_1", "attempt_2",
    "w1c_event_race", "report_swap_read", "poll_ms", "poll_binterval",
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
