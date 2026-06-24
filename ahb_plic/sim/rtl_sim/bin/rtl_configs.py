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
# Consumed by run_lint_sweep.py (and, in the future, by a sim-side sweep
# runner once the testbench gains parameter passthrough).
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
    ("default",              {}),                                                # NH=1, SU=1, NS=31, PB=3, AW=22 (RTL defaults)
    ("nh1_su0",              {"SU_MODE_EN": 0}),                                 # Elide S-context routing (G_IRQ_M_ONLY branch)
    ("nh2_su1",              {"NUM_HARTS": 2}),                                  # Multi-hart M+S interleaving (4 contexts)
    ("nh2_su0",              {"NUM_HARTS": 2, "SU_MODE_EN": 0}),                 # Multi-hart M-only (2 contexts)
    ("nh4_su1",              {"NUM_HARTS": 4}),                                  # 8 contexts
    ("ns63_pb4",             {"NUM_SOURCES": 63, "PRIO_BITS": 4}),               # Multi-word pending/enable + wider priority
    ("ns127_pb7",            {"NUM_SOURCES": 127, "PRIO_BITS": 7}),              # 4 pending/enable words, max priority width
    ("nh4_su1_ns63_pb4",     {"NUM_HARTS": 4, "NUM_SOURCES": 63, "PRIO_BITS": 4}), # Combined corner: 8 contexts x 2 words
]

TOP_MODULE = "ahb_plic"
