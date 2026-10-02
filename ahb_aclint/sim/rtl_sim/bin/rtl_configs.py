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
# covered explicitly (both 0 and 1). ASYNC_RST_EN is covered because the reset
# style selects a DIFFERENT hand-written branch inside arv_synchronizer -- and
# that branch's whole justification (keeping the reset mux out of the
# meta -> sync path, for MTBF) is a physical-timing property that only synthesis
# and STA can check.
#
# BOTH SU_MODE_EN VALUES MUST BE LISTED EXPLICITLY. The RTL default is 0 (as in
# the core), so the default config elides aclint_sswi; the *_su1 entries are what
# lint, synthesise, DFT-check and time it (the feature axes below also pin
# SU_MODE_EN=1 so they cross SSWI). Without them the module would go
# unchecked while the sweep reported clean -- the sim sweep defaults the other
# way (the bench sets SU_MODE_EN=1) and would hide the gap. Every generate
# branch needs an entry that reaches it.
#----------------------------------------------------------------------------

CONFIGS = [
    # label            parameter overrides
    ("default",        {}),                                                     # NH=1, SU=0 (RTL defaults) -- elides aclint_sswi
    ("nh1_su0",        {"SU_MODE_EN": 0}),                                      # Elide aclint_sswi explicitly (G_NO_SSWI branch)
    ("nh2_su1",        {"NUM_HARTS": 2, "SU_MODE_EN": 1}),                      # Multi-hart MSWI/SSWI decode
    ("nh4_su1",        {"NUM_HARTS": 4, "SU_MODE_EN": 1}),                      # Wider hart vector
    ("nh16_su0",       {"NUM_HARTS": 16, "SU_MODE_EN": 0}),                     # Max hart count, SU elided
    ("nh16_su1",       {"NUM_HARTS": 16, "SU_MODE_EN": 1}),                     # Max hart count, all features on
    ("priv_off",       {"PRIV_CHECK_EN": 0, "SU_MODE_EN": 1}),                  # Privilege check disabled
    ("sync_rst",       {"ASYNC_RST_EN": 0, "SU_MODE_EN": 1}),                   # Synchronous reset: the ONLY config that builds the arv_ipdff / arv_synchronizer sync-reset branches
    ("lf_sync",        {"LF_SYNC_EN": 1, "SU_MODE_EN": 1}),                     # Synchronous timebase (FPGA): no LF domain, MTIME paced by an internal tick
    ("lf_sync_rst",    {"LF_SYNC_EN": 1, "ASYNC_RST_EN": 0, "SU_MODE_EN": 1}),  # Both together -- the FPGA persona. Neither axis alone builds the sync-reset branches inside the LF_SYNC_EN=1 elaboration
]

TOP_MODULE = "ahb_aclint"
