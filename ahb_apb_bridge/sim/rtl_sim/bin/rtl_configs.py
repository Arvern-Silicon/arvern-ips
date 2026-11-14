#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    rtl_configs.py (ahb_apb_bridge)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the ahb_apb_bridge RTL parameterization sweep set.
#
# Consumed by run_lint_sweep.py, lint/vc_static/run_vclint and
# synthesis/synopsys/run_syn (-rtl_config / -rtl_sweep). The simulation sweep
# has its own table, sim_configs.py, driven through the bench's defines.
#
# Each entry is (label, {PARAM: value}). Unspecified parameters take their
# RTL default. The label is used to name log files and the summary column.
#
# Coverage rationale: SLV_NR sizes every APB vector and selects the read-data
# path (a single completer has no mux); ADDRW sizes the address and the window
# masks, with a completer window as large as the bridge window (mask 0) as
# its own case, ADDRW = 4 the narrowest and ADDRW = 31 the widest legal
# window; ASYNC_RST_EN selects the reset branches.
#----------------------------------------------------------------------------


def packed(fields, width):
    """Pack per-completer values, completer 0 in the low bits, as a sized hex literal."""
    v = 0
    for k, f in enumerate(fields):
        v |= f << (k * width)
    return "%d'h%x" % (len(fields) * width, v)


CONFIGS = [
    # label        parameter overrides
    ("default",    {}),                                                        # 2 completers, 4 KB window, 256 B each
    ("one",        {"SLV_NR": 1, "ADDRW": 8,
                    "SLV_BASE": packed([0], 8), "SLV_AW": packed([8], 5)}),                              # one completer owning the whole window (no mux, mask 0)
    ("s4_mixed",   {"SLV_NR": 4, "ADDRW": 12,
                    "SLV_BASE": packed([0x000, 0x400, 0x800, 0xC00], 12),
                    "SLV_AW": packed([8, 10, 4, 2], 5)}),                      # mixed window sizes, gaps between them
    ("s16",        {"SLV_NR": 16, "ADDRW": 16,
                    "SLV_BASE": packed([k * 0x1000 for k in range(16)], 16),
                    "SLV_AW": packed([12] * 16, 5)}),                          # the largest completer count
    ("aw31",       {"SLV_NR": 2, "ADDRW": 31,
                    "SLV_BASE": packed([0x0000_0000, 0x4000_0000], 31),
                    "SLV_AW": packed([16, 30], 5)}),                           # the widest address, a window of half the bridge
    ("aw4",        {"SLV_NR": 2, "ADDRW": 4,
                    "SLV_BASE": packed([0x0, 0x8], 4),
                    "SLV_AW": packed([2, 3], 5)}),                             # the narrowest address: a one-word and a two-word window, a gap
    ("sync_rst",   {"ASYNC_RST_EN": 0}),                                       # synchronous reset branches
]

TOP_MODULE = "ahb_apb_bridge"
