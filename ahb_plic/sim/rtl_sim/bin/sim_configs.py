#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    sim_configs.py (ahb_plic)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the ahb_plic simulation sweep set.
#
# Each entry is (label, defines, test_list):
#   - label     : config name used for log directories and the summary table
#   - defines   : dict of {DEFINE_NAME: value} -- forwarded to iverilog via -D
#   - test_list : ordered list of test names (file basenames in sim/rtl_sim/src/)
#
# Defines drive the testbench parameterization (see tb_ahb_plic.v: the TB
# `\`define`s control NUM_SOURCES / NUM_HARTS / SU_MODE_EN / PRIO_BITS at
# elaboration). Tests incompatible with a config are omitted from its
# test_list.
#----------------------------------------------------------------------------

DEFAULT_TESTS = [
    "priority_rdwr",
    "enable_rdwr",
    "pending_gateway",
    "threshold_claim",
    "arbiter_tiebreak",
    "m_s_routing",
    "unmapped_access",
    # Spec-compliance regressions (PLIC 1.0.0 Chapters 8 and 9):
    "claim_threshold_independent",
    "complete_invalid_id",
    # Security: per-privilege register access policy (PRIV_CHECK_EN=1).
    "priv_check",
    # Coverage/check-gap closures (spec corners + AHB protocol + clock-gate):
    "priority_zero",
    "threshold_boundary",
    "size_check",
    "reset_values",
    "ahb_error_p2",
    "pending_gated_wake",
    "random_irq",
]

MULTIWORD_TESTS = [
    "priority_multiword",
    "enable_multiword",
    "pending_multiword",
]

SIM_CONFIGS = [
    # (label,        defines,                                                          test_list)
    ("default",      {},                                                               DEFAULT_TESTS),
    ("nh2",          {"PLIC_NUM_HARTS": 2},                                            ["priority_rdwr", "enable_rdwr", "unmapped_access", "multihart_routing"]),
    ("nh4",          {"PLIC_NUM_HARTS": 4},                                            ["priority_rdwr", "enable_rdwr", "unmapped_access", "multihart_routing"]),
    # SU=0 elides the S-context address windows: enable_rdwr's ctx-1 sub-section
    # would land in a non-existent context (RAZ/WI) and the readback fails. Skip
    # it here -- the multi-word and routing tests cover the rest.
    ("su0",          {"PLIC_SU_MODE_EN": 0},                                           ["priority_rdwr", "pending_gateway", "threshold_claim", "unmapped_access", "su_disabled"]),
    ("nh2_su0",      {"PLIC_NUM_HARTS": 2, "PLIC_SU_MODE_EN": 0},                      ["priority_rdwr", "unmapped_access", "su_disabled"]),
    # priority_rdwr's last sub-section asserts PRIO_BITS=3 truncation (expected
    # 0x7 from an all-ones write); enable_rdwr's last sub-section asserts that
    # enable word 1 is RAZ (true only at NUM_SOURCES<=31). Both are correct at
    # the default config and covered at higher NS/PB by the dedicated multiword
    # tests, so they're omitted from these expanded configs.
    ("ns63_pb4",     {"PLIC_NUM_SOURCES": 63, "PLIC_PRIO_BITS": 4},                    ["pending_gateway", "threshold_claim", "arbiter_tiebreak", "m_s_routing", "unmapped_access"] + MULTIWORD_TESTS),
    ("ns127_pb7",    {"PLIC_NUM_SOURCES": 127, "PLIC_PRIO_BITS": 7},                   ["unmapped_access"] + MULTIWORD_TESTS),
    # PRIV_CHECK_EN=0 bypass -- verifies the filter can be cleanly disabled.
    ("priv_off",     {"PLIC_PRIV_CHECK_EN": 0},                                   ["priority_rdwr", "enable_rdwr", "unmapped_access", "priv_check_off", "size_check"]),
    # ASYNC_RST_EN=0 synchronous-reset build -- mirrors the arvern core RTL-config
    # sweep over ASYNC_RST_EN. Full default test list (priority/pending/enable/
    # target/arbiter/AHB paths) re-run against synchronously-reset flops.
    ("sync_rst",     {"PLIC_ASYNC_RST_EN": 0},                                    DEFAULT_TESTS),
]

TB_TOP = "tb_ahb_plic"

# Functional-coverage gate (homegrown, see bench/verilog/cover_monitor.v).
# Each test emits "COVERAGE HIT: <bin>" lines; run_sweep.py unions them across
# EVERY (config, test) run and FAILS the sweep if any bin below was never hit
# in any config. Suite-level visibility for unexercised states/interfaces --
# the blind spot that hid the sibling ACLINT clock-gate bug. A bin only needs
# one config to count, so config-specific bins (multiword at ns63/ns127,
# eip_s_hi at SU=1) are fine.
MANDATORY_COVER_BINS = [
    # External-interrupt outputs (formerly only spot-checked)
    "eip_m_hi", "eip_s_hi",
    # Clock-gate advisory exercised both directions
    "hclk_en_hi", "hclk_en_lo",
    # AHB error path
    "hresp_err", "size_err",
    # Gateway / arbiter state
    "pending_any", "in_service_any", "claim_nonzero", "claim_pulse", "complete_pulse",
    # Spec corners that gate dedicated RTL terms
    "prio0_blocked", "threshold_masks",
    # Multi-word (source index > 31)
    "multiword",
]
