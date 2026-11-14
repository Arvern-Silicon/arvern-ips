#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    rtl_configs.py (apb_periph_example)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the apb_periph_example RTL parameterization sweep set.
#
# Consumed by run_lint_sweep.py, lint/vc_static/run_vclint and
# synthesis/synopsys/run_syn (-rtl_config / -rtl_sweep). The simulation sweep
# has its own table, sim_configs.py, driven through the bench's defines.
#
# Each entry is (label, {PARAM: value}). Unspecified parameters take their
# RTL default. The label is used to name log files and the summary column.
#
# Coverage rationale: ADDRW sizes the address decode, with the minimum of 7 as
# the default and wider windows checking that nothing relies on it;
# ASYNC_RST_EN selects the reset branches; MDELEG_RST sets the MDELEG reset
# constants, and "open" differs from the default in every field.
#----------------------------------------------------------------------------

CONFIGS = [
    # label        parameter overrides
    ("default",    {}),                          # ADDRW=7, async reset (RTL defaults)
    ("sync_rst",   {"ASYNC_RST_EN": 0}),         # synchronous reset branches
    ("addrw8",     {"ADDRW": 8}),                # window above the minimum
    ("addrw12",    {"ADDRW": 12}),               # a 4 KB window, the usual APB slot
    ("open",       {"MDELEG_RST": "9'h001"}),    # MDELEG reset: S writes, U reads, refusals ignored
]

TOP_MODULE = "apb_periph_example"
