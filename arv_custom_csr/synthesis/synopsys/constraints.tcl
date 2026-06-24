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
#       AHB INTERFACE      #
#==========================#

# Inputs
set CCSR_BANK_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set CCSR_REG_SEL_DLY [expr ($CLOCK_PERIOD/100) * 20]
set CCSR_WDATA_DLY   [expr ($CLOCK_PERIOD/100) * 20]
set CCSR_WEN_DLY     [expr ($CLOCK_PERIOD/100) * 20]

# Outputs
set CCSR_RDATA_DLY   [expr ($CLOCK_PERIOD/100) * 70]


set_input_delay $CCSR_BANK_DLY               -max -clock "hclk"   [get_ports ccsr_bank_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports ccsr_bank_i]

set_input_delay $CCSR_REG_SEL_DLY            -max -clock "hclk"   [get_ports ccsr_reg_sel_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports ccsr_reg_sel_i]

set_input_delay $CCSR_WDATA_DLY              -max -clock "hclk"   [get_ports ccsr_wdata_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports ccsr_wdata_i]

set_input_delay $CCSR_WEN_DLY                -max -clock "hclk"   [get_ports ccsr_wen_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports ccsr_wen_i]


set_output_delay $CCSR_RDATA_DLY  -add_delay -max -clock "hclk"   [get_ports ccsr_rdata_o]
set_output_delay 0                           -min -clock "hclk"   [get_ports ccsr_rdata_o]


#=========================#
# REGISTER OUTPUT PORTS   #
#=========================#

set CCSR_USR_RW_DLY      [expr ($CLOCK_PERIOD/100) * 75]
set CCSR_SUP_RW_DLY      [expr ($CLOCK_PERIOD/100) * 75]
set CCSR_MAC_RW_DLY      [expr ($CLOCK_PERIOD/100) * 75]

set_output_delay $CCSR_USR_RW_DLY     -add_delay -max -clock "hclk"   [get_ports ccsr_usr_rw_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports ccsr_usr_rw_o]

set_output_delay $CCSR_SUP_RW_DLY     -add_delay -max -clock "hclk"   [get_ports ccsr_sup_rw_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports ccsr_sup_rw_o]

set_output_delay $CCSR_MAC_RW_DLY     -add_delay -max -clock "hclk"   [get_ports ccsr_mac_rw_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports ccsr_mac_rw_o]

#=========================#
# REGISTER INPUT PORTS    #
#=========================#

set CCSR_USR_RO_DLY      [expr ($CLOCK_PERIOD/100) * 20]
set CCSR_SUP_RO_DLY      [expr ($CLOCK_PERIOD/100) * 20]
set CCSR_MAC_RO_DLY      [expr ($CLOCK_PERIOD/100) * 20]

set_input_delay $CCSR_USR_RO_DLY             -max -clock "hclk"   [get_ports ccsr_usr_ro_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports ccsr_usr_ro_i]

set_input_delay $CCSR_SUP_RO_DLY             -max -clock "hclk"   [get_ports ccsr_sup_ro_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports ccsr_sup_ro_i]

set_input_delay $CCSR_MAC_RO_DLY             -max -clock "hclk"   [get_ports ccsr_mac_ro_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports ccsr_mac_ro_i]

#=========================#
# REMAINING OUTPUT PORTS  #
#=========================#

set HCLK_EN_DLY      [expr ($CLOCK_PERIOD/100) * 75]

set_output_delay $HCLK_EN_DLY     -add_delay -max -clock "hclk"   [get_ports hclk_en_o]
set_output_delay 0                           -min -clock "hclk"   [get_ports hclk_en_o]


#========================#
# FEEDTHROUGH EXCEPTIONS #
#========================#

#set_max_delay [expr 2.0 + $DMEM_DOUT_DLY + $DMEM_ADDR_DLY] \
#              -from       [get_ports dmem_dout]            \
#              -to         [get_ports dmem_addr]            \
#              -group_path FEEDTHROUGH


#===============#
# FALSE PATHS   #
#===============#

set_false_path -from hresetn_i
