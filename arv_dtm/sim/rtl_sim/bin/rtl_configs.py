#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    rtl_configs.py (arv_dtm)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the arv_dtm RTL parameterization lint sweep.
#
# Consumed by run_lint_sweep.py. Each transport has its own toplevel, so the
# sweep pairs a top module with a set of parameter overrides.
#
# TOPS  : the transport toplevels (plus the arv_dtm wrapper) linted at their
#         defaults by the plain
#         `./run_lint` (no -sweep). Kept here as the single source of truth.
# CONFIGS : (label, top_module, {PARAM: value}) points for `./run_lint -sweep`.
#           Unspecified parameters take their RTL default; the label names the
#           per-config log file and the summary-table row.
#
# Coverage rationale -- parameters that gate generate blocks or resize buses:
#   ARST_EN    (all)  : async- vs sync-reset generate arms in arv_ipdff /
#                       arv_synchronizer -- lint both reset styles.
# (The UART DTM has no baud parameter: auto-baud is its only mode, always compiled.)
# IDCODE / IDLE_HINT (jtag) are pure constants (no generate / width impact), so
# they are not swept. DMI_ABITS is fixed internally. The wrapper's
# UART_RX_FIFO_DEPTH (resizes the FIFO pointers) and I2C_WD_BITS (watchdog width)
# get one non-default point each; I2C_ADDR is a constant on the wrapper and a
# port on arv_dtm_i2c.
#----------------------------------------------------------------------------

# Transport toplevels (also hard-listed in run_lint's default loop; mirrored
# here so the sweep and any future tooling share one definition).
TOPS = [
    "arv_dtm_jtag",
    "arv_dtm_uart",
    "arv_dtm_i2c",
    "arv_dtm_cjtag",
    "arv_dtm",
]

CONFIGS = [
    # label               top module        parameter overrides
    # --- JTAG ---
    ("jtag_default",       "arv_dtm_jtag",   {}),
    ("jtag_syncrst",       "arv_dtm_jtag",   {"ARST_EN": 0}),

    # --- UART ---
    ("uart_default",       "arv_dtm_uart",   {}),
    ("uart_syncrst",       "arv_dtm_uart",   {"ARST_EN": 0}),

    # --- I2C ---
    ("i2c_default",        "arv_dtm_i2c",    {}),
    ("i2c_syncrst",        "arv_dtm_i2c",    {"ARST_EN": 0}),
    # --- cJTAG (IEEE 1149.7 OScan1) ---
    ("cjtag_default",      "arv_dtm_cjtag",  {}),
    ("cjtag_syncrst",      "arv_dtm_cjtag",  {"ARST_EN": 0}),                 # clk_i side only; the TCKC domain is always async (TCK_ARST)
    # --- arv_dtm wrapper: one entry per transport the DTM_TYPE mux can select ---
    ("wrap_jtag",          "arv_dtm",        {"DTM_TYPE": 0}),
    ("wrap_uart",          "arv_dtm",        {"DTM_TYPE": 1}),
    ("wrap_i2c",           "arv_dtm",        {"DTM_TYPE": 2}),
    ("wrap_cjtag",         "arv_dtm",        {"DTM_TYPE": 3}),
    ("wrap_uart_fifo128",  "arv_dtm",        {"DTM_TYPE": 1, "UART_RX_FIFO_DEPTH": 128}),  # the FPGA's depth: resizes the FIFO pointers
    ("wrap_i2c_wd20",      "arv_dtm",        {"DTM_TYPE": 2, "I2C_WD_BITS": 20}),          # non-default watchdog width
]
