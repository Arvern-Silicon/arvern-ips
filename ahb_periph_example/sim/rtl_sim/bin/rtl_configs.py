#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    rtl_configs.py (ahb_periph_example)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the ahb_periph_example RTL parameterization sweep set.
#
# Consumed by lint/vc_static/run_vclint and synthesis/synopsys/run_syn
# (-rtl_config / -rtl_sweep) through bin/gen_rtl_params.py. The simulation
# regression (sim/rtl_sim/run/run_all) runs the same builds from its own list;
# a new config goes in both.
#
# Each entry is (label, {PARAM: value}). Unspecified parameters take their
# RTL default. The label is used to name log files and the summary column.
#
# Coverage rationale: the register bank has no generate-gating parameter.
# The synchronous-reset config is the ONLY one that builds the arv_ipdff
# sync-reset branch, and rules.tcl enforces the opposite reset rule for it.
# ADDRW sizes the address window and the one-hot decoder; a build above the
# minimum of 7 checks that nothing relies on the default width.
#----------------------------------------------------------------------------

CONFIGS = [
    # label        parameter overrides
    ("default",    {}),                          # ADDRW=7, async reset (RTL defaults)
    ("sync_rst",   {"ASYNC_RST_EN": 0}),         # Synchronous reset: builds the arv_ipdff sync branches
    ("addrw8",     {"ADDRW": 8}),                # Wider window: decoder sized above the minimum
]
TOP_MODULE = "ahb_periph_example"
