#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    rtl_configs.py (ahb_plic)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the ahb_plic RTL parameterization sweep set.
#
# Consumed by run_lint_sweep.py, lint/vc_static/run_vclint and
# synthesis/synopsys/run_syn (-rtl_config / -rtl_sweep). The simulation sweep
# has its own table, sim_configs.py, driven through the bench's defines.
#
# Each entry is (label, {PARAM: value}). Unspecified parameters take their
# RTL default. The label is used to name log files and the summary column.
#
# Coverage rationale: parameters that gate generate blocks or change
# interface widths are SU_MODE_EN (decides 1 or 2 contexts per hart),
# NUM_HARTS (sizes irq vectors and the M/S routing generate),
# NUM_SOURCES (decides word count for pending/enable; >31 lights up
# word 1), and PRIO_BITS (priority compare width).
#----------------------------------------------------------------------------

CONFIGS = [
    # label                  parameter overrides
    ("default",              {}),                                                                   # NH=1, SU=0, NS=31, PB=3, AW=22 (RTL defaults)
    ("nh1_su1",              {"SU_MODE_EN": 1}),                                                     # Default sizes with the S-contexts (the RTL default builds M-only)
    ("nh2_su1",              {"NUM_HARTS": 2, "SU_MODE_EN": 1}),                                    # Multi-hart M+S interleaving (4 contexts)
    ("nh2_su0",              {"NUM_HARTS": 2, "SU_MODE_EN": 0}),                                    # Multi-hart M-only (2 contexts)
    ("nh4_su1",              {"NUM_HARTS": 4, "SU_MODE_EN": 1}),                                    # 8 contexts
    ("ns63_pb4",             {"NUM_SOURCES": 63, "PRIO_BITS": 4, "SU_MODE_EN": 1}),                 # Multi-word pending/enable + wider priority
    ("ns127_pb7",            {"NUM_SOURCES": 127, "PRIO_BITS": 7, "SU_MODE_EN": 1}),                # 4 pending/enable words, max priority width
    ("nh4_su1_ns63_pb4",     {"NUM_HARTS": 4, "NUM_SOURCES": 63, "PRIO_BITS": 4, "SU_MODE_EN": 1}), # Combined corner: 8 contexts x 2 words
    ("ns40_pb1",             {"NUM_SOURCES": 40, "PRIO_BITS": 1, "SU_MODE_EN": 1}),                 # Non-power-of-two source count (padded arbiter leaves), 1-bit priority
    ("sync_rst",             {"ASYNC_RST_EN": 0, "SU_MODE_EN": 1}),                                 # Synchronous reset: the ONLY config that builds the arv_ipdff sync-reset branches
]

TOP_MODULE = "ahb_plic"
