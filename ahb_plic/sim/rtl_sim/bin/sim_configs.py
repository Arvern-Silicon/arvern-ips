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
    # AHB traffic the blocking BFM never issues, ERROR interactions, and the
    # per-context privilege policy:
    "bus_pipelined",
    "error_hold",
    "priv_contexts",
    # Address-bit walk and access policy, reset under load, pipelined claim/complete:
    "addr_walk",
    "reset_in_operation",
    "claim_complete_pipelined",
    # Source walk, threshold range ends, enable / priority changes under a live source:
    "source_walk",
    "threshold_extremes",
    "enable_priority_dynamics",
    "pair_contests",
]

# Default-config tests not re-run in sync_rst.
DEFAULT_ONLY_TESTS = [
    "source_walk",
    "threshold_extremes",
    "enable_priority_dynamics",
    "pair_contests",
]

MULTIWORD_TESTS = [
    "priority_multiword",
    "enable_multiword",
    "pending_multiword",
]

SIM_CONFIGS = [
    # (label,        defines,                                                          test_list)
    ("default",      {},                                                               DEFAULT_TESTS),
    ("nh2",          {"PLIC_NUM_HARTS": 2},                                            ["priority_rdwr", "enable_rdwr", "unmapped_access", "multihart_routing", "priv_contexts", "context_walk", "addr_walk"]),
    ("nh4",          {"PLIC_NUM_HARTS": 4},                                            ["priority_rdwr", "enable_rdwr", "unmapped_access", "multihart_routing", "priv_contexts", "context_walk", "addr_walk"]),
    # SU=0 elides the S-context address windows: enable_rdwr's ctx-1 sub-section
    # would land in a non-existent context (RAZ/WI) and the readback fails. Skip
    # it here -- the multi-word and routing tests cover the rest.
    ("su0",          {"PLIC_SU_MODE_EN": 0},                                           ["priority_rdwr", "pending_gateway", "threshold_claim", "unmapped_access", "su_disabled", "priv_contexts", "context_walk", "addr_walk", "enable_priority_dynamics"]),
    ("nh2_su0",      {"PLIC_NUM_HARTS": 2, "PLIC_SU_MODE_EN": 0},                      ["priority_rdwr", "unmapped_access", "su_disabled", "priv_contexts", "context_walk", "addr_walk"]),
    # priority_rdwr's last sub-section asserts PRIO_BITS=3 truncation (expected
    # 0x7 from an all-ones write); enable_rdwr's last sub-section asserts that
    # enable word 1 is RAZ (true only at NUM_SOURCES<=31). Both are correct at
    # the default config and covered at higher NS/PB by the dedicated multiword
    # tests, so they're omitted from these expanded configs.
    ("ns63_pb4",     {"PLIC_NUM_SOURCES": 63, "PLIC_PRIO_BITS": 4},                    ["pending_gateway", "threshold_claim", "arbiter_tiebreak", "m_s_routing", "unmapped_access", "source_walk", "threshold_extremes", "addr_walk", "context_walk", "pair_contests"] + MULTIWORD_TESTS),
    ("ns127_pb7",    {"PLIC_NUM_SOURCES": 127, "PLIC_PRIO_BITS": 7},                   ["unmapped_access", "source_walk", "threshold_extremes", "addr_walk",
                                                                                        "threshold_claim", "arbiter_tiebreak", "m_s_routing", "priority_zero",
                                                                                        "threshold_boundary", "complete_invalid_id", "priv_contexts", "random_irq",
                                                                                        "context_walk", "pair_contests"] + MULTIWORD_TESTS),
    # PRIO_BITS=1 (every non-zero priority is 1, threshold 1 masks everything) with a
    # source count that is not a multiple of 32. Tests writing literal priorities or
    # thresholds above 1 (threshold_claim, threshold_boundary, claim_threshold_independent,
    # priv_contexts) do not apply.
    ("ns40_pb1",     {"PLIC_NUM_SOURCES": 40, "PLIC_PRIO_BITS": 1},                    ["source_walk", "threshold_extremes", "addr_walk", "unmapped_access",
                                                                                        "pending_gateway", "arbiter_tiebreak", "m_s_routing", "priority_zero",
                                                                                        "complete_invalid_id", "random_irq", "reset_values", "pair_contests"] + MULTIWORD_TESTS),
    # PRIV_CHECK_EN=0 bypass -- verifies the filter can be cleanly disabled.
    # Contexts 2..7 only exist with NUM_HARTS > 1; with more than 31 sources their
    # claim / completion IDs reach bits 5 and up (mirrors rtl_configs nh4_su1_ns63_pb4).
    ("nh4_ns63_pb4", {"PLIC_NUM_HARTS": 4, "PLIC_NUM_SOURCES": 63, "PLIC_PRIO_BITS": 4}, ["context_walk", "unmapped_access", "addr_walk", "priv_contexts"]),
    ("priv_off",     {"PLIC_PRIV_CHECK_EN": 0},                                   ["priority_rdwr", "enable_rdwr", "unmapped_access", "priv_check_off", "size_check", "addr_walk"]),
    # ASYNC_RST_EN=0 synchronous-reset build -- mirrors the arvern core RTL-config
    # sweep over ASYNC_RST_EN. Full default test list (priority/pending/enable/
    # target/arbiter/AHB paths) re-run against synchronously-reset flops.
    ("sync_rst",     {"PLIC_ASYNC_RST_EN": 0},                                    [t for t in DEFAULT_TESTS if t not in DEFAULT_ONLY_TESTS]),
]

TB_TOP = "tb_ahb_plic"

# Functional-coverage gate (homegrown, see bench/verilog/cover_monitor.v).
# Each test emits "COVERAGE HIT: <bin>" lines; run_sweep.py unions them across
# EVERY (config, test) run and FAILS the sweep if any bin below was never hit
# in any config: suite-level visibility for states and interfaces no test
# reaches, which a passing test list alone cannot show. A bin only needs
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
