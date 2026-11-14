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
# Module Description : Timing constraints: clock, path groups, boundary I/O
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


create_clock -name     "hclk"                                 \
             -period   "$CLOCK_PERIOD"                        \
             -waveform "0 [expr $CLOCK_PERIOD/2]" \
             [get_ports hclk_i]


##############################################################################
#                                                                            #
#                          CREATE PATH GROUPS                                #
#                                                                            #
##############################################################################

group_path -name REGOUT      -to   [all_outputs]
group_path -name REGIN       -from [remove_from_collection [all_inputs] [get_ports hclk_i]]
group_path -name FEEDTHROUGH -from [remove_from_collection [all_inputs] [get_ports hclk_i]] -to [all_outputs]


##############################################################################
#                                                                            #
#                          BOUNDARY TIMINGS                                  #
#                                                                            #
##############################################################################

#==========================#
#       AHB-LITE SLAVE     #
#==========================#

# Inputs (20% of clock period -- standard for register-bank slaves where the
# inbound side is fully registered into dph_* on the next clock edge).
set HSEL_DLY      [expr ($CLOCK_PERIOD/100) * 20]
set HADDR_DLY     [expr ($CLOCK_PERIOD/100) * 20]
set HWRITE_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set HSIZE_DLY     [expr ($CLOCK_PERIOD/100) * 20]
set HTRANS_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set HPROT_DLY     [expr ($CLOCK_PERIOD/100) * 20]
set HSMODE_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set HMASTER_DLY   [expr ($CLOCK_PERIOD/100) * 20]
set HREADY_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set HWDATA_DLY    [expr ($CLOCK_PERIOD/100) * 20]

# Outputs (85% of clock period -- HRDATA, HREADYOUT and HRESP come from
# flops in this IP, so they leave nearly the whole cycle to the fabric's
# return mux)
set HRDATA_DLY    [expr ($CLOCK_PERIOD/100) * 85]
set HREADYOUT_DLY [expr ($CLOCK_PERIOD/100) * 85]
set HRESP_DLY     [expr ($CLOCK_PERIOD/100) * 85]


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

set_input_delay $HMASTER_DLY  -max -clock "hclk"   [get_ports hmaster_i]
set_input_delay 0             -min -clock "hclk"   [get_ports hmaster_i]

set_input_delay $HREADY_DLY   -max -clock "hclk"   [get_ports hready_i]
set_input_delay 0             -min -clock "hclk"   [get_ports hready_i]

set_input_delay $HWDATA_DLY   -max -clock "hclk"   [get_ports hwdata_i]
set_input_delay 0             -min -clock "hclk"   [get_ports hwdata_i]


set_output_delay $HRDATA_DLY     -add_delay -max -clock "hclk"   [get_ports hrdata_o]
set_output_delay 0                          -min -clock "hclk"   [get_ports hrdata_o]

set_output_delay $HREADYOUT_DLY  -add_delay -max -clock "hclk"   [get_ports hreadyout_o]
set_output_delay 0                          -min -clock "hclk"   [get_ports hreadyout_o]

set_output_delay $HRESP_DLY      -add_delay -max -clock "hclk"   [get_ports hresp_o]
set_output_delay 0                          -min -clock "hclk"   [get_ports hresp_o]


#==========================#
#      APB4 REQUESTER      #
#==========================#

# Control outputs come from flops; the completers decode them in the same
# cycle (70% budget). PWDATA is HWDATA passed through (20% in, 40% out).
set APB_CTL_DLY   [expr ($CLOCK_PERIOD/100) * 70]
set PWDATA_DLY    [expr ($CLOCK_PERIOD/100) * 40]

foreach p {psel_o paddr_o penable_o pwrite_o pstrb_o pprot_o psmode_o pmaster_o} {
    set_output_delay $APB_CTL_DLY -add_delay -max -clock "hclk" [get_ports $p]
    set_output_delay 0                       -min -clock "hclk" [get_ports $p]
}
set_output_delay $PWDATA_DLY  -add_delay -max -clock "hclk"   [get_ports pwdata_o]
set_output_delay 0                       -min -clock "hclk"   [get_ports pwdata_o]

# Completer responses: a completer's read mux and ready logic come first
# (60% budget); the bridge only registers them.
set APB_RSP_DLY   [expr ($CLOCK_PERIOD/100) * 60]

foreach p {prdata_i pready_i pslverr_i} {
    set_input_delay $APB_RSP_DLY -max -clock "hclk" [get_ports $p]
    set_input_delay 0            -min -clock "hclk" [get_ports $p]
}


#==========================#
#    CLOCK-GATE ADVISORY   #
#==========================#

# Drives a SoC-side ICG cell -- 75% budget matches arv_custom_csr's
# hclk_en_o convention.
set HCLK_EN_DLY   [expr ($CLOCK_PERIOD/100) * 75]

set_output_delay $HCLK_EN_DLY  -add_delay -max -clock "hclk"   [get_ports hclk_en_o]
set_output_delay 0                        -min -clock "hclk"   [get_ports hclk_en_o]


#===============#
# FALSE PATHS   #
#===============#

set_false_path -from hresetn_i
