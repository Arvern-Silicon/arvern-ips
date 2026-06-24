#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    rtl_configs.py (ahb_aclint)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the ahb_aclint RTL parameterization sweep set.
#
# Consumed by run_lint_sweep.py (and, in the future, by a sim-side sweep
# runner once the testbench gains parameter passthrough).
#
# Each entry is (label, {PARAM: value}). Unspecified parameters take their
# RTL default. The label is used to name log files and the summary column.
#
# Coverage rationale: the IP's parameters that gate generate blocks or
# change interface widths are SU_MODE_EN (gates aclint_sswi) and NUM_HARTS
# (sizes irq vectors and per-hart register banks). PRIV_CHECK_EN is also
# covered explicitly (both 0 and 1).
#----------------------------------------------------------------------------

CONFIGS = [
    # label            parameter overrides
    ("default",        {}),                                                    # NH=1, SU=1 (RTL defaults)
    ("nh1_su0",        {"SU_MODE_EN": 0}),                                     # Elide aclint_sswi (G_NO_SSWI branch)
    ("nh2_su1",        {"NUM_HARTS": 2}),                                      # Multi-hart MSWI/SSWI decode
    ("nh4_su1",        {"NUM_HARTS": 4}),                                      # Wider hart vector
    ("nh16_su0",       {"NUM_HARTS": 16, "SU_MODE_EN": 0}),                    # Max hart count, SU elided
    ("nh16_su1",       {"NUM_HARTS": 16}),                                     # Max hart count, all features on
    ("priv_off",       {"PRIV_CHECK_EN": 0}),                                  # Privilege check disabled
]

TOP_MODULE = "ahb_aclint"
