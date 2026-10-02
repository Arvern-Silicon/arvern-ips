#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    constraints_ports.arv_dtm_cjtag
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : constraints_ports.arv_dtm_cjtag.tcl
# Module Description : Clocks, CDC budgets, path groups, boundary I/O delays,
#                      reset false-paths and DFT port lists for the cJTAG DTM
#                      (arv_dtm_cjtag, or arv_dtm with DTM_TYPE=3).
#
#   DUAL-clock:
#     - clk_i  : always-on oscillator (escape detector + DMI / APB4 half)
#     - tckc_i : probe clock (OScan1 scan engine, activation FSM, the TAP, the
#                TCK half of arv_dtm_dmi_master; u_esc_type_ng and the TAP's
#                TDO flops run on its FALLING edge)
#   The two are ASYNCHRONOUS. Crossings:
#     clk_i -> tckc_i
#       - esc_tog              -> u_esc_tog_sync (synchroniser)
#       - esc_class (u_esc_cnt)-> u_esc_type_ng, negedge, NO synchroniser (budgeted)
#       - esc_hit / esc_pending-> tmsc_oe_o (combinational, release-only)
#       - DMI response payload -> u_rdata_tck/u_cstat_tck      (budgeted)
#       - ack / hardreset toggles -> synchronisers
#     tckc_i -> clk_i
#       - tckc_i, tmsc_i pins  -> u_esc_tckc_sync / u_esc_tmsc_sync
#       - esc_tog_tckc         -> esc_pending -> tmsc_oe_o
#       - online -> tap_rst_n_i -> u_tap/u_hclk_rst_sync async reset
#       - DMI request payload  -> u_hreq_*                      (budgeted)
#       - req toggle           -> synchroniser
#----------------------------------------------------------------------------

##############################################################################
#                                                                            #
#                            CLOCK DEFINITION                                #
#                                                                            #
##############################################################################

create_clock -name     "clk"                                  \
             -period   "$CLOCK_PERIOD"                        \
             -waveform "0 [expr $CLOCK_PERIOD/2]"             \
             [get_ports clk_i]

# TCKC. The escape detector oversamples TMSC on clk_i while TCKC is held high,
# and the esc_class capture below relies on clk_i >= 8x TCKC, so the probe
# clock is modelled at exactly that ratio.
set TCKC_PERIOD [expr $CLOCK_PERIOD * 8]
create_clock -name     "tckc"                                 \
             -period   "$TCKC_PERIOD"                         \
             -waveform "0 [expr $TCKC_PERIOD/2]"              \
             [get_ports tckc_i]

set ::DTM_SYS_CLK "clk"


##############################################################################
#                                                                            #
#                        CLOCK-DOMAIN CROSSINGS                              #
#                                                                            #
##############################################################################

# Blanket: every tckc <-> clk path bounded to one destination period.
dtm_async_pair tckc $TCKC_PERIOD clk $CLOCK_PERIOD

# (a) Escape class -> framing capture. esc_class is decoded from the clk_i
# escape counter u_esc_cnt and captured WITHOUT a synchroniser by u_esc_type_ng
# on the terminating falling edge of TCKC. The crossing is timing-based: the
# class settles during the escape, many clk_i cycles before that edge, which
# holds only because clk_i >= 8x TCKC. Budget: the multi-bit decode must reach
# the capture flop within ONE clk_i period, so every bit has settled by the
# clk_i edge after the last counter update (well inside the TCKC-high phase).
dtm_max_delay $CLOCK_PERIOD -from [dtm_regs "*u_esc_cnt/*"] \
                            -to   [dtm_regs "*u_esc_type_ng/*"]

# (b) DMI request/response payload buses (toggle-handshake qualified).
dtm_dmi_payload_cdc $TCKC_PERIOD $CLOCK_PERIOD


##############################################################################
#                                                                            #
#                          CREATE PATH GROUPS                                #
#                                                                            #
##############################################################################

dtm_path_groups {tckc_i clk_i}


##############################################################################
#                                                                            #
#                          BOUNDARY TIMINGS                                  #
#                                                                            #
##############################################################################

#==================================#
#     cJTAG 2-WIRE PHY  (tckc)      #
#==================================#
# TMSC is one bidirectional pad split into tmsc_i / tmsc_o / tmsc_oe_o.
# Probe -> target phases (nTDI, TMS, activation) are sampled on the rising TCKC
# edge: same treatment as JTAG TMS/TDI. The target drives TDO while TCKC is low:
#   - tmsc_o comes from the TAP's falling-edge TDO flop: same treatment as JTAG
#     TDO (60 % of the period, relative to the falling edge).
#   - tmsc_oe_o is combinational: ~tckc_i itself (clock used as data) AND the
#     rising-edge phase counter, plus the release-only escape terms. Its
#     rising-edge-launched paths only get half a period to the falling-edge
#     reference, so the JTAG 60 % would be unmeetable by construction; 20 %
#     keeps the enable inside the first part of the TCKC-low phase.

set TMSC_IN_DLY   [expr ($TCKC_PERIOD/100) * 20]
set TMSC_OUT_DLY  [expr ($TCKC_PERIOD/100) * 60]
set TMSC_OE_DLY   [expr ($TCKC_PERIOD/100) * 20]
set WAKE_DLY      [expr ($TCKC_PERIOD/100) * 60]
set IDVER_DLY     [expr ($TCKC_PERIOD/100) * 20]

set_input_delay  $TMSC_IN_DLY              -max -clock "tckc"             [get_ports tmsc_i]
set_input_delay  0                         -min -clock "tckc"             [get_ports tmsc_i]

# tmsc_i is ALSO oversampled by the clk_i escape detector through the 2-FF
# synchroniser u_esc_tmsc_sync. The input delay above is relative to TCKC and
# has no meaning to clk_i (it would exceed the clk_i-period CDC bound on its
# own), so that one synchroniser input is cut.
set_false_path -from [get_ports tmsc_i] -to [dtm_regs "*u_esc_tmsc_sync/*"]

set_output_delay $TMSC_OUT_DLY  -add_delay -max -clock "tckc" -clock_fall [get_ports tmsc_o]
set_output_delay 0                         -min -clock "tckc" -clock_fall [get_ports tmsc_o]

set_output_delay $TMSC_OE_DLY   -add_delay -max -clock "tckc" -clock_fall [get_ports tmsc_oe_o]
set_output_delay 0                         -min -clock "tckc" -clock_fall [get_ports tmsc_oe_o]

# Cold-attach wake toggle: a tckc-domain flop, detected asynchronously by the
# SoC's always-on controller.
set_output_delay $WAKE_DLY      -add_delay -max -clock "tckc"             [get_ports dbg_wakeup_o]
set_output_delay 0                         -min -clock "tckc"             [get_ports dbg_wakeup_o]

# IDCODE version: quasi-static ECO strap, captured into the IDCODE DR on tckc.
set_input_delay  $IDVER_DLY                -max -clock "tckc"             [get_ports idcode_version_i]
set_input_delay  0                         -min -clock "tckc"             [get_ports idcode_version_i]


#==================================#
#     DMI / APB4 MASTER  (clk)      #
#==================================#

dtm_dmi_apb_io clk $CLOCK_PERIOD


#===============#
# FALSE PATHS   #
#===============#

set_false_path -from [get_ports dbgresetn_i]


##############################################################################
#                                                                            #
#                    DFT SCAN-CLOCK / RESET PORT LISTS                       #
#                                                                            #
#   Flops on both clocks (both edges of tckc_i). dbgresetn_i reaches the     #
#   TCKC-domain flops and the TAP's hclk reset synchroniser as an async      #
#   reset in every build, but with ARST_EN=0 it also enters u_clk_rst_sync   #
#   on the D side: declared Reset there, DRC would see a clock-like signal   #
#   on data pins (D10). In that build it is held inactive as a test-mode     #
#   constant, which gives up ATPG coverage of the TCKC-side reset tree.      #
#                                                                            #
##############################################################################

set ::DFT_SCAN_CLOCKS {tckc_i 45 55 clk_i 45 55}
if {$DTM_ARST_EN} {
    set ::DFT_RESETS    {dbgresetn_i 0}
} else {
    set ::DFT_CONSTANTS {dbgresetn_i 1}
}
