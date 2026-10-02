#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    rtl_configs.py (arv_custom_csr)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the arv_custom_csr RTL parameterization sweep set.
#
# Consumed by lint/vc_static/run_vclint and synthesis/synopsys/run_syn
# (-rtl_config / -rtl_sweep) through bin/gen_rtl_params.py, and by the
# simulation regression (sim/rtl_sim/run/run_all) through
# bin/rtl_configs_defines.py, which runs the configuration-independent tests
# on every entry.
#
# Each entry is (label, {PARAM: value}). Unspecified parameters take their
# RTL default. The label is used to name log files and the summary column.
#
# Coverage rationale: each NR_* count gates a generate branch and sizes a
# port, so the corners are a disabled group (0: the WITHOUT_* branches and
# 1-bit ports), a single register, a group crossing into its second bank
# (65), and the maxima (the pad bit keeping the *_unused slices legal).
# The synchronous-reset config is the ONLY one that builds the arv_ipdff
# sync-reset branch, and rules.tcl enforces the opposite reset rule for it.
#----------------------------------------------------------------------------

CONFIGS = [
    # label        parameter overrides
    ("default",    {}),                                                        # 6/2 usr, 4/2 sup, 2/1 mac (RTL defaults)
    ("min_banks",  {"NR_USR_RW": 1, "NR_USR_RO": 1, "NR_SUP_RW": 1,
                    "NR_SUP_RO": 1, "NR_MAC_RW": 1, "NR_MAC_RO": 1}),          # Every bank at its minimum
    ("wide_banks", {"NR_USR_RW": 8, "NR_USR_RO": 8, "NR_SUP_RW": 8,
                    "NR_SUP_RO": 8, "NR_MAC_RW": 8, "NR_MAC_RO": 8}),          # Every bank wider than default
    ("sync_rst",   {"ASYNC_RST_EN": 0}),                                       # Synchronous reset: builds the arv_ipdff sync branches
    ("ro_only",    {"NR_USR_RW": 0, "NR_SUP_RW": 0, "NR_MAC_RW": 0}),          # No RW group: no flop, clock/reset/write inputs sunk
    ("rw_only",    {"NR_USR_RO": 0, "NR_SUP_RO": 0, "NR_MAC_RO": 0}),          # No RO group: 1-bit RO ports sunk
    ("no_sup",     {"NR_SUP_RW": 0, "NR_SUP_RO": 0}),                          # Supervisor banks disabled (SU_MODE_EN=0 cores)
    ("two_banks",  {"NR_USR_RW": 65, "NR_SUP_RW": 65, "NR_MAC_RW": 65}),       # Every RW group crosses into its second bank
    ("max_banks",  {"NR_USR_RW": 256, "NR_USR_RO": 64, "NR_SUP_RW": 128,
                    "NR_SUP_RO": 64, "NR_MAC_RW": 128, "NR_MAC_RO": 60}),      # Every group at its maximum
]
TOP_MODULE = "arv_custom_csr"
