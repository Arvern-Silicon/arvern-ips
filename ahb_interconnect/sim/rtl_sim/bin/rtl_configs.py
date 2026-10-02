#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    rtl_configs.py (ahb_interconnect)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the ahb_interconnect RTL parameterization sweep set.
#
# Consumed by lint/vc_static/run_vclint (-rtl_config / -rtl_sweep) through
# bin/gen_rtl_params.py. There is no Verilator or simulation sweep runner for
# this IP yet; when one is added it should read this table too.
#
# Each entry is (label, top, {PARAM: value}): this IP has several top-level
# modules, so every config names the one it elaborates. Unspecified parameters
# take their RTL default. The label names log files and the summary column.
#
# Coverage rationale: the three fabric variants are separate modules sharing
# the same external contract (see doc/ahb_interconnect.md), so each is a top.
# For the fused variant NR_S_X_ROM=0 is a distinct generate branch (no ROM
# controller, rom_* ports tied off, rom_dout_i sunk) and is what the FPGA
# board builds, so it gets its own entry. Each top has a synchronous-reset
# config: that is the ONLY one that builds the arv_ipdff sync-reset branches,
# and rules.tcl enforces the opposite reset rule for it.
#----------------------------------------------------------------------------

CONFIGS = [
    # label                top module                  parameter overrides
    # --- generic (single-layer) ---
    ("generic_default",    "ahb_interconnect_generic", {}),                        # NR_M=3, NR_S=5 (RTL defaults)
    ("generic_syncrst",    "ahb_interconnect_generic", {"ASYNC_RST_EN": 0}),
    # --- hiperf (multi-layer, executable / non-executable split) ---
    ("hiperf_default",     "ahb_interconnect_hiperf",  {}),                        # NR_M=2, NR_S_X=2, NR_S_NX=3
    ("hiperf_syncrst",     "ahb_interconnect_hiperf",  {"ASYNC_RST_EN": 0}),
    # --- fused (ROM / SRAM controllers folded into the fabric) ---
    ("fused_default",      "ahb_interconnect_fused",   {}),                        # NR_S_X_ROM=1, NR_S_X_SRAM=1, NR_S_NX=3
    ("fused_norom",        "ahb_interconnect_fused",   {"NR_S_X_ROM": 0}),         # No ROM slot: ROM_ABSENT_TIEOFF branch (FPGA board)
    ("fused_syncrst",      "ahb_interconnect_fused",   {"ASYNC_RST_EN": 0}),
]
