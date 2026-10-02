#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    rtl_configs.py (ahb_sram_controller)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the ahb_sram_controller RTL parameterization sweep set.
#
# Consumed by lint/vc_static/run_vclint and synthesis/synopsys/run_syn
# (-rtl_config / -rtl_sweep) through bin/gen_rtl_params.py. The simulation
# regression (sim/rtl_sim/run/run_all) runs the matching builds from its own
# list; a new config goes in both.
#
# Each entry is (label, {PARAM: value}). Unspecified parameters take their
# RTL default. The label is used to name log files and the summary column.
#
# Coverage rationale: MEM_SIZE sizes the address ports (haddr_i, sram_addr_o),
# the write-address buffer and the read-from-pause compare; the minimum (8
# bytes, a one-bit word address) and a large size check the slices at both
# ends. The synchronous-reset config is the ONLY one that builds the arv_ipdff
# sync-reset branch, and rules.tcl enforces the opposite reset rule for it.
#----------------------------------------------------------------------------

CONFIGS = [
    # label        parameter overrides
    ("default",    {}),                          # MEM_SIZE=256, async reset (RTL defaults)
    ("sync_rst",   {"ASYNC_RST_EN": 0}),         # Synchronous reset: builds the arv_ipdff sync branches
    ("mem8",       {"MEM_SIZE": 8}),             # Minimum size: one-bit word address
    ("mem64k",     {"MEM_SIZE": 65536}),         # Large size: 14-bit word address
]
TOP_MODULE = "ahb_sram_controller"
