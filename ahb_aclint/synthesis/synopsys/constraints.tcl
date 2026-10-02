#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    constraints
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : constraints.tcl
# Module Description : Timing constraints: clocks, path groups, boundary I/O
#                      delays, and false paths.
#----------------------------------------------------------------------------

##############################################################################
#                                                                            #
#                            CLOCK DEFINITION                                #
#                                                                            #
##############################################################################

#set CLOCK_PERIOD 100.0; #  10 MHz
#set CLOCK_PERIOD 66.6; #  15 MHz
#set CLOCK_PERIOD 50.0; #  20 MHz
#set CLOCK_PERIOD 40.0; #  25 MHz
#set CLOCK_PERIOD 33.3; #  30 MHz
#set CLOCK_PERIOD 30.0; #  33 MHz
#set CLOCK_PERIOD 25.0; #  40 MHz
#set CLOCK_PERIOD 22.2; #  45 MHz
#set CLOCK_PERIOD 20.0; #  50 MHz
#set CLOCK_PERIOD 16.7; #  60 MHz
#set CLOCK_PERIOD 15.4; #  65 MHz
set CLOCK_PERIOD 15.0; #  66 MHz
#set CLOCK_PERIOD 14.3; #  70 MHz
#set CLOCK_PERIOD 12.5; #  80 MHz
#set CLOCK_PERIOD 11.1; #  90 MHz
#set CLOCK_PERIOD 10.0; # 100 MHz
#set CLOCK_PERIOD  8.0; # 125 MHz


# hclk_i and hclk_aon_i are the same physical clock at the SoC level
create_clock -name     "hclk"                                       \
             -period   "$CLOCK_PERIOD"                              \
             -waveform "0 [expr $CLOCK_PERIOD/2]"                   \
             [get_ports {hclk_i hclk_aon_i}]

# Low-frequency always-on clock. 32.768 kHz
set CLK_LF_PERIOD 30517.578125; # 32.768 kHz

create_clock -name     "clk_lf"                                     \
             -period   "$CLK_LF_PERIOD"                             \
             -waveform "0 [expr $CLK_LF_PERIOD/2]"                  \
             [get_ports clk_lf_i]

set LF_REGS   [all_registers -clock clk_lf]
set HCLK_REGS [all_registers -clock hclk]

# An empty LF_REGS is the signature of LF_SYNC_EN=1: nothing is clocked by
# clk_lf_i, so there is no LF domain.
set LF_SYNC_MODE [expr {[sizeof_collection $LF_REGS] == 0}]


##############################################################################
#                        hclk <-> clk_lf CROSSINGS                           #
##############################################################################
# The MTIMER crosses these domains WITHOUT a handshake: each side may only move
# at a time the other is not sampling (see aclint_lf_tick.v). Both directions
# are therefore ordinary timing-constrained paths and must be CONSTRAINED, not
# declared asynchronous -- a set_clock_groups -asynchronous here would make the
# tool report clean and the part fail intermittently in silicon.
#
# Written -from/-to REGISTER COLLECTIONS, not [get_clocks ...]: at a ~3000:1
# period ratio a clock-based exception exceeds DC's clock-expansion limit (1000)
# and is silently dropped, leaving the endpoints unconstrained while the run
# still reports timing MET.
# Both budgets are derived in aclint_lf_tick.v ("tick timing and the two
# budgets"): the tick lands 3 to 5 hclk after the clk_lf edge.
if {!$LF_SYNC_MODE} {
    # LF -> hclk: launched on the clk_lf edge, captured on lf_tick >= 3 hclk later.
    set_max_delay [expr 3 * $CLOCK_PERIOD] \
                  -from $LF_REGS -to $HCLK_REGS

    # hclk -> LF: launched on lf_tick <= 5 hclk after the clk_lf edge, sampled
    # by the NEXT clk_lf edge.
    set_max_delay [expr $CLK_LF_PERIOD - 5 * $CLOCK_PERIOD] \
                  -from $HCLK_REGS -to $LF_REGS
}


##############################################################################
#                                                                            #
#                          CREATE PATH GROUPS                                #
#                                                                            #
##############################################################################

group_path -name REGOUT      -to   [all_outputs]
group_path -name REGIN       -from [remove_from_collection [all_inputs] [get_ports {hclk_i hclk_aon_i clk_lf_i}]]
group_path -name FEEDTHROUGH -from [remove_from_collection [all_inputs] [get_ports {hclk_i hclk_aon_i clk_lf_i}]] -to [all_outputs]


##############################################################################
#                                                                            #
#                          BOUNDARY TIMINGS                                  #
#                                                                            #
##############################################################################

#==========================#
#       AHB-LITE SLAVE     #
#==========================#

# Inputs
set HSEL_DLY      [expr ($CLOCK_PERIOD/100) * 20]
set HADDR_DLY     [expr ($CLOCK_PERIOD/100) * 20]
set HWRITE_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set HSIZE_DLY     [expr ($CLOCK_PERIOD/100) * 20]
set HTRANS_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set HPROT_DLY     [expr ($CLOCK_PERIOD/100) * 20]
set HSMODE_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set HREADY_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set AONEN_DLY     [expr ($CLOCK_PERIOD/100) * 20]
set HWDATA_DLY    [expr ($CLOCK_PERIOD/100) * 20]

# Outputs
set HRDATA_DLY    [expr ($CLOCK_PERIOD/100) * 70]
set HREADYOUT_DLY [expr ($CLOCK_PERIOD/100) * 70]
set HRESP_DLY     [expr ($CLOCK_PERIOD/100) * 70]


set_input_delay $HSEL_DLY     -max -clock "hclk"   [get_ports hsel_i]
set_input_delay 0             -min -clock "hclk"   [get_ports hsel_i]

set_input_delay $HADDR_DLY    -max -clock "hclk"   [get_ports haddr_i]
set_input_delay 0             -min -clock "hclk"   [get_ports haddr_i]

set_input_delay $HWRITE_DLY   -max -clock "hclk"   [get_ports hwrite_i]
set_input_delay 0             -min -clock "hclk"   [get_ports hwrite_i]

set_input_delay $HSIZE_DLY    -max -clock "hclk"   [get_ports hsize_i]
set_input_delay 0             -min -clock "hclk"   [get_ports hsize_i]

set_input_delay $HTRANS_DLY   -max -clock "hclk"   [get_ports htrans_i]
set_input_delay 0             -min -clock "hclk"   [get_ports htrans_i]

set_input_delay $HPROT_DLY    -max -clock "hclk"   [get_ports hprot_i]
set_input_delay 0             -min -clock "hclk"   [get_ports hprot_i]

set_input_delay $HSMODE_DLY   -max -clock "hclk"   [get_ports hsmode_i]
set_input_delay 0             -min -clock "hclk"   [get_ports hsmode_i]

set_input_delay $HREADY_DLY   -max -clock "hclk"   [get_ports hready_i]
set_input_delay 0             -min -clock "hclk"   [get_ports hready_i]

# hclk_aon_en_i is not a reset and not a test constant -- it gates hresetn_i into
# the LF-tick trust reset, so it is real logic in every config and needs timing.
set_input_delay $AONEN_DLY    -max -clock "hclk"   [get_ports hclk_aon_en_i]
set_input_delay 0             -min -clock "hclk"   [get_ports hclk_aon_en_i]

set_input_delay $HWDATA_DLY   -max -clock "hclk"   [get_ports hwdata_i]
set_input_delay 0             -min -clock "hclk"   [get_ports hwdata_i]


set_output_delay $HRDATA_DLY     -add_delay -max -clock "hclk"   [get_ports hrdata_o]
set_output_delay 0                          -min -clock "hclk"   [get_ports hrdata_o]

set_output_delay $HREADYOUT_DLY  -add_delay -max -clock "hclk"   [get_ports hreadyout_o]
set_output_delay 0                          -min -clock "hclk"   [get_ports hreadyout_o]

set_output_delay $HRESP_DLY      -add_delay -max -clock "hclk"   [get_ports hresp_o]
set_output_delay 0                          -min -clock "hclk"   [get_ports hresp_o]


#==========================#
#  ZICNTR TIME SIDE-BAND   #
#==========================#

set TIME_REQ_DLY  [expr ($CLOCK_PERIOD/100) * 20]

set_input_delay $TIME_REQ_DLY -max -clock "hclk"   [get_ports time_req_i]
set_input_delay 0             -min -clock "hclk"   [get_ports time_req_i]


set TIME_GNT_DLY  [expr ($CLOCK_PERIOD/100) * 75]
set TIME_VAL_DLY  [expr ($CLOCK_PERIOD/100) * 75]

set_output_delay $TIME_GNT_DLY  -add_delay -max -clock "hclk"   [get_ports time_gnt_o]
set_output_delay 0                         -min -clock "hclk"   [get_ports time_gnt_o]

set_output_delay $TIME_VAL_DLY  -add_delay -max -clock "hclk"   [get_ports time_val_o]
set_output_delay 0                         -min -clock "hclk"   [get_ports time_val_o]


#==========================#
#  PER-HART IRQ OUTPUTS    #
#==========================#

set IRQ_MSI_DLY   [expr ($CLOCK_PERIOD/100) * 75]
set IRQ_MTI_DLY   [expr ($CLOCK_PERIOD/100) * 75]
set IRQ_SSI_DLY   [expr ($CLOCK_PERIOD/100) * 75]

set_output_delay $IRQ_MSI_DLY  -add_delay -max -clock "hclk"   [get_ports irq_m_software_o]
set_output_delay 0                        -min -clock "hclk"   [get_ports irq_m_software_o]

set_output_delay $IRQ_MTI_DLY  -add_delay -max -clock "hclk"   [get_ports irq_m_timer_o]
set_output_delay 0                        -min -clock "hclk"   [get_ports irq_m_timer_o]

set_output_delay $IRQ_SSI_DLY  -add_delay -max -clock "hclk"   [get_ports irq_s_software_o]
set_output_delay 0                        -min -clock "hclk"   [get_ports irq_s_software_o]


#==========================#
#    CLOCK-GATE ADVISORY   #
#==========================#

set HCLK_EN_DLY   [expr ($CLOCK_PERIOD/100) * 75]

set_output_delay $HCLK_EN_DLY  -add_delay -max -clock "hclk"   [get_ports hclk_en_o]
set_output_delay 0                        -min -clock "hclk"   [get_ports hclk_en_o]


#==========================#
#  LF-DOMAIN WAKE OUTPUT   #
#==========================#

set WAKE_LF_DLY   [expr ($CLK_LF_PERIOD/100) * 75]

# mtimer_wake_lf_o is launched by whichever clock the comparator runs on, which is the mode.
if {$LF_SYNC_MODE} {
    set WAKE_HCLK_DLY [expr ($CLOCK_PERIOD/100) * 75]
    set_output_delay $WAKE_HCLK_DLY -add_delay -max -clock "hclk"   [get_ports mtimer_wake_lf_o]
    set_output_delay 0                         -min -clock "hclk"   [get_ports mtimer_wake_lf_o]
} else {
    set_output_delay $WAKE_LF_DLY  -add_delay  -max -clock "clk_lf" [get_ports mtimer_wake_lf_o]
    set_output_delay 0                         -min -clock "clk_lf" [get_ports mtimer_wake_lf_o]
}


#===============#
# FALSE PATHS   #
#===============#

# scan_mode_i is a test-mode constant: no functional path through it to time.
set_false_path -from scan_mode_i

# THE RESET FALSE PATHS ARE CONDITIONAL ON THE RESET STYLE.
#
# With ASYNC_RST_EN=1 the resets drive asynchronous clear pins and there is
# genuinely nothing to time. With ASYNC_RST_EN=0 the same nets are ORDINARY
# SYNCHRONOUS DATA feeding the flops' D-side mux, and false-pathing them leaves
# those paths unconstrained -- silently, since an unconstrained path is not a
# violation. Give them an input delay instead.
set ASYNC_RST_MODE [expr {![info exists RTL_PARAM_ASYNC_RST_EN] || $RTL_PARAM_ASYNC_RST_EN}]

if {$ASYNC_RST_MODE} {
    set_false_path -from hresetn_i
    set_false_path -from resetn_lf_i
} else {
    set_input_delay $AONEN_DLY -max -clock "hclk"   [get_ports hresetn_i]
    set_input_delay 0          -min -clock "hclk"   [get_ports hresetn_i]
    if {!$LF_SYNC_MODE} {
        set_input_delay $AONEN_DLY -max -clock "clk_lf" [get_ports resetn_lf_i]
        set_input_delay 0          -min -clock "clk_lf" [get_ports resetn_lf_i]
    } else {
        set_false_path -from resetn_lf_i
    }
}
