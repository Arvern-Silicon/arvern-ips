#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    constraints_ports.arv_dtm_jtag
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : constraints_ports.arv_dtm_jtag.tcl
# Module Description : Clocks, CDC budgets, path groups, boundary I/O delays,
#                      reset false-paths and DFT port lists for the JTAG DTM
#                      (arv_dtm_jtag, or arv_dtm with DTM_TYPE=0).
#
#   DUAL-clock:
#     - tck_i  : JTAG test clock (TAP + the TCK half of arv_dtm_dmi_master)
#     - hclk_i : always-on oscillator (DMI / APB4 half). The arv_dtm wrapper
#                binds it to clk_i: the port is DTM_SYS_CLK_PORT when set.
#   The two are ASYNCHRONOUS. Crossings (all in arv_dtm_tap / dmi_master):
#     - req/ack/hardreset toggle levels -> arv_synchronizer first stages
#     - request payload u_req_latch -> u_hreq_*                  (budgeted)
#     - response payload u_rsp_*_h -> u_rdata_tck/u_cstat_tck    (budgeted)
#     - tap_rst_n_i -> u_hclk_rst_sync async reset (always async, HCLK_ARST)
#----------------------------------------------------------------------------

if {![info exists DTM_SYS_CLK_PORT]} { set DTM_SYS_CLK_PORT hclk_i }

##############################################################################
#                                                                            #
#                            CLOCK DEFINITION                                #
#                                                                            #
##############################################################################

# System / DMI clock (ungated oscillator).
create_clock -name     "hclk"                                 \
             -period   "$CLOCK_PERIOD"                        \
             -waveform "0 [expr $CLOCK_PERIOD/2]"             \
             [get_ports $DTM_SYS_CLK_PORT]

# JTAG test clock. TCK is a slow, externally-driven test clock; make it
# comfortably slower than hclk (its own paths are just the TAP shift chain).
set TCK_PERIOD [expr $CLOCK_PERIOD * 4]
create_clock -name     "tck"                                  \
             -period   "$TCK_PERIOD"                          \
             -waveform "0 [expr $TCK_PERIOD/2]"               \
             [get_ports tck_i]

set ::DTM_SYS_CLK "hclk"


##############################################################################
#                                                                            #
#                        CLOCK-DOMAIN CROSSINGS                              #
#                                                                            #
##############################################################################

# Blanket: every tck <-> hclk path bounded to one destination period.
dtm_async_pair tck $TCK_PERIOD hclk $CLOCK_PERIOD

# DMI request/response payload buses (toggle-handshake qualified).
dtm_dmi_payload_cdc $TCK_PERIOD $CLOCK_PERIOD


##############################################################################
#                                                                            #
#                          CREATE PATH GROUPS                                #
#                                                                            #
##############################################################################

dtm_path_groups [list tck_i $DTM_SYS_CLK_PORT]


##############################################################################
#                                                                            #
#                          BOUNDARY TIMINGS                                  #
#                                                                            #
##############################################################################

#==================================#
#      JTAG TAP PORTS  (tck)        #
#==================================#

set TMS_DLY       [expr ($TCK_PERIOD/100) * 20]
set TDI_DLY       [expr ($TCK_PERIOD/100) * 20]
set TDO_DLY       [expr ($TCK_PERIOD/100) * 60]
set TDO_OE_DLY    [expr ($TCK_PERIOD/100) * 60]
set WAKE_DLY      [expr ($TCK_PERIOD/100) * 60]
set IDVER_DLY     [expr ($TCK_PERIOD/100) * 20]

set_input_delay $TMS_DLY                  -max -clock "tck"    [get_ports tms_i]
set_input_delay 0                         -min -clock "tck"    [get_ports tms_i]

set_input_delay $TDI_DLY                  -max -clock "tck"    [get_ports tdi_i]
set_input_delay 0                         -min -clock "tck"    [get_ports tdi_i]

# TDO / TDO_OE are launched on the FALLING TCK edge (spec-standard); constrain
# them relative to the tck falling edge.
set_output_delay $TDO_DLY      -add_delay -max -clock "tck" -clock_fall [get_ports tdo_o]
set_output_delay 0                        -min -clock "tck" -clock_fall [get_ports tdo_o]

set_output_delay $TDO_OE_DLY   -add_delay -max -clock "tck" -clock_fall [get_ports tdo_oe_o]
set_output_delay 0                        -min -clock "tck" -clock_fall [get_ports tdo_oe_o]

# Cold-attach wake toggle: a tck-domain flop, detected asynchronously by the
# SoC's always-on controller.
set_output_delay $WAKE_DLY     -add_delay -max -clock "tck"             [get_ports dbg_wakeup_o]
set_output_delay 0                        -min -clock "tck"             [get_ports dbg_wakeup_o]

# IDCODE version: quasi-static ECO strap, captured into the IDCODE DR on tck.
set_input_delay $IDVER_DLY                -max -clock "tck"    [get_ports idcode_version_i]
set_input_delay 0                         -min -clock "tck"    [get_ports idcode_version_i]


#==================================#
#     DMI / APB4 MASTER  (hclk)     #
#==================================#

dtm_dmi_apb_io hclk $CLOCK_PERIOD


#===============#
# FALSE PATHS   #
#===============#

set_false_path -from [get_ports trst_n_i]
set_false_path -from [get_ports dbgresetn_i]


##############################################################################
#                                                                            #
#                    DFT SCAN-CLOCK / RESET PORT LISTS                       #
#                                                                            #
#   Flops on BOTH clocks, so both are scan clocks. trst_n_i and dbgresetn_i  #
#   reach the TAP's two reset synchronisers and the wake toggle, all         #
#   asynchronous in every build (TCK_ARST / HCLK_ARST), so both stay Reset   #
#   even when ARST_EN=0 (the hclk-side sync resets come from a synchroniser  #
#   output, held inactive in test by scan_mode_i).                           #
#                                                                            #
##############################################################################

set ::DFT_SCAN_CLOCKS [list tck_i 45 55 $DTM_SYS_CLK_PORT 45 55]
set ::DFT_RESETS      {trst_n_i 0 dbgresetn_i 0}
