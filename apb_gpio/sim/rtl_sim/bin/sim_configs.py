#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    sim_configs.py (apb_gpio)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the apb_gpio simulation test list and sweep set.
#
# Each SIM_CONFIGS entry is (label, defines, test_list):
#   - label     : config name used for log file names and the summary table
#   - defines   : dict of {DEFINE_NAME: value} -- forwarded to iverilog via -D
#   - test_list : ordered list of test names (file basenames in sim/rtl_sim/src/)
#
# The defines drive the testbench parameterization (tb_apb_gpio.v):
#   GPIO_TB_NR, GPIO_TB_ADDRW, GPIO_TB_SYNC_EN, GPIO_TB_MDELEG_RST (decimal),
#   GPIO_TB_ASYNC_RST_EN, GPIO_TB_INP_CGATE_EN, GPIO_TB_ALT_NR -> the DUT
#   parameters of the same name.
#
# Every test adapts to the parameters it runs under (GPIO_MASK, L_IN,
# MDELEG_RST, ...), so DEFAULT_TESTS runs in every config that changes
# behaviour. A test that has nothing to check in a config prints SIMULATION
# SKIPPED (counted separately, never as a failure).
#
#   run_all          -> REGRESSION_CONFIGS (default + the configs that flip a
#                       behaviour-visible parameter); logs <test>.log for the
#                       default config, <test>--<label>.log otherwise
#   run_all -sweep   -> every SIM_CONFIGS entry (bin/run_sweep.py)
#   run_all -cov     -> every SIM_CONFIGS pair under Verilator (bin/runcov)
#   run <test> -config <label>  -> one test in one config
#----------------------------------------------------------------------------

# Alternate functions (adapt to ALT_NR; skip where they have nothing to check)
ALT_TESTS = [
    "alt_registers",
    "alt_routing",
    "alt_switch",
    "alt_input_path",
    "alt_random",
]

DEFAULT_TESTS = [
    # Register file
    "reset_values",
    "output_oe_rdwr",
    "out_set_clr_tgl",
    "oe_irq_en_set_clr",
    "byte_lanes",
    "gpio_nr_mask",
    "unmapped_info",
    "cfg_irq_stat",
    # Input stage
    "input_latency",
    "input_readback",
    "post_reset_edge",
    "in_en_flush",
    # Interrupts
    "irq_edge",
    "irq_w1c_race",
    "irq_level",
    "irq_enable_gating",
    "irq_mode_no_event",
    "irq_bus_gated",
    # Wake request
    "wake_running",
    "wake_osc_off",
    "wake_polarity",
    # Access protection (MDELEG; the tests set it, mdeleg_reset checks MDELEG_RST)
    "priv_check",
    "mdeleg_access",
    "mdeleg_reset",
    "pslverr_timing",
    # Clock gating and APB protocol
    "pclk_gating",
    "back_to_back",
    "idle_bus",
    # Randomised pins / bus traffic against the bench reference model
    "random_stress",
] + ALT_TESTS

# Tests worth re-running when only the pin count or the window changes.
NR_TESTS = [
    "reset_values",
    "output_oe_rdwr",
    "out_set_clr_tgl",
    "oe_irq_en_set_clr",
    "byte_lanes",
    "gpio_nr_mask",
    "unmapped_info",
    "cfg_irq_stat",
    "input_latency",
    "irq_edge",
    "irq_level",
    "irq_enable_gating",
    "in_en_flush",
    "irq_bus_gated",
    "wake_running",
    "wake_osc_off",
    "wake_polarity",
    "pclk_gating",
    "random_stress",
]
ADDR_TESTS = [
    "reset_values",
    "unmapped_info",
    "output_oe_rdwr",
    "priv_check",
    "mdeleg_access",
    "back_to_back",
    "random_stress",
]

SIM_CONFIGS = [
    # (label,            defines,                                                           test_list)
    # RTL defaults: GPIO_NR=32, ADDRW=7, SYNC_EN=1, MDELEG_RST=9'h10F, ALT_NR=0, ASYNC_RST_EN=1
    ("default",          {},                                                                DEFAULT_TESTS),
    # MDELEG open out of reset (9'h000: User / User, silent drop), the FPGA boards' setting
    ("open",             {"GPIO_TB_MDELEG_RST": 0},                                         DEFAULT_TESTS),
    # Synchronous reset: pclk_en_o must keep the clock running during reset
    ("sync_rst",         {"GPIO_TB_ASYNC_RST_EN": 0},                                       DEFAULT_TESTS),
    # No input-path clock gate (FPGA): same behaviour, input path always clocked
    ("no_cgate",         {"GPIO_TB_INP_CGATE_EN": 0},                                       DEFAULT_TESTS),
    ("no_cgate_sync_rst", {"GPIO_TB_INP_CGATE_EN": 0, "GPIO_TB_ASYNC_RST_EN": 0},           DEFAULT_TESTS),
    # Synchronous pins: single input register, one-edge INPUT latency
    ("nosync",           {"GPIO_TB_SYNC_EN": 0},                                            DEFAULT_TESTS),
    # Pin count corners: one pin, a byte, a non-lane-aligned count, one short of 32
    ("nr1",              {"GPIO_TB_NR": 1},                                                 DEFAULT_TESTS),
    ("nr8",              {"GPIO_TB_NR": 8},                                                 NR_TESTS),
    ("nr13_nosync",      {"GPIO_TB_NR": 13, "GPIO_TB_SYNC_EN": 0},                          DEFAULT_TESTS),
    ("nr31",             {"GPIO_TB_NR": 31},                                                NR_TESTS),
    # Window width: decode above the minimum, and the maximum
    ("addrw8",           {"GPIO_TB_ADDRW": 8},                                              ADDR_TESTS),
    ("addrw16",          {"GPIO_TB_ADDRW": 16},                                             ADDR_TESTS),
    # Every non-default value at once
    ("mixed",            {"GPIO_TB_NR": 20, "GPIO_TB_ADDRW": 9, "GPIO_TB_SYNC_EN": 0,
                          "GPIO_TB_MDELEG_RST": 1, "GPIO_TB_ASYNC_RST_EN": 0},               DEFAULT_TESTS),
    # Alternate functions: every register count, the out-of-range number (ALT_NR=3)
    ("alt1",             {"GPIO_TB_ALT_NR": 1},                                             DEFAULT_TESTS),
    ("alt2",             {"GPIO_TB_ALT_NR": 2},                                             DEFAULT_TESTS),
    ("alt3",             {"GPIO_TB_ALT_NR": 3},                                             DEFAULT_TESTS),
    ("alt4",             {"GPIO_TB_ALT_NR": 4},                                             DEFAULT_TESTS),
    ("alt4_nr13_open",   {"GPIO_TB_ALT_NR": 4, "GPIO_TB_NR": 13, "GPIO_TB_MDELEG_RST": 0,
                          "GPIO_TB_ASYNC_RST_EN": 0},                                        DEFAULT_TESTS),
    ("alt3_nr1_addrw8",  {"GPIO_TB_ALT_NR": 3, "GPIO_TB_NR": 1, "GPIO_TB_ADDRW": 8},        DEFAULT_TESTS),
    # Synchronous reset with Supervisor gates (9'h105) and a small port
    ("sync_rst_smode_nr5", {"GPIO_TB_NR": 5, "GPIO_TB_MDELEG_RST": 261,
                          "GPIO_TB_ASYNC_RST_EN": 0},                                        DEFAULT_TESTS),
]

# Configs run by a plain `run_all` (the regression); `run_all -sweep` runs all.
REGRESSION_CONFIGS = ["default", "open", "sync_rst", "nosync", "no_cgate", "alt3", "alt4"]

TB_TOP = "tb_apb_gpio"

# Functional coverage gate of the sweep: every bin must be hit in at least one
# (config, test) run (the tb's cover_report prints "COVERAGE HIT: <bin>")
MANDATORY_COVER_BINS = [
    "write", "read", "back_to_back", "pslverr", "partial_strobe",
    "penable_without_psel", "w1c_edge_race", "in_en_flush", "wake_osc_off",
    "pclk_gated", "reset_in_transfer", "alt_owned", "level_irq", "edge_irq",
    "silent_drop", "smode_admitted", "umode_admitted", "wake_polarity_masked",
    "oe_irq_en_alias",
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
