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

# Clock period can be set by the library setup file (setup_*.tcl).
# If not already defined, use the default value below.
if {![info exists CLOCK_PERIOD]} {
    #set CLOCK_PERIOD 100.0; #  10 MHz
    #set CLOCK_PERIOD 66.6;  #  15 MHz
    #set CLOCK_PERIOD 50.0;  #  20 MHz
    #set CLOCK_PERIOD 40.0;  #  25 MHz
    #set CLOCK_PERIOD 33.3;  #  30 MHz
    #set CLOCK_PERIOD 30.0;  #  33 MHz
    #set CLOCK_PERIOD 25.0;  #  40 MHz
    #set CLOCK_PERIOD 22.2;  #  45 MHz
    #set CLOCK_PERIOD 20.0;  #  50 MHz
    #set CLOCK_PERIOD 16.7;  #  60 MHz
    #set CLOCK_PERIOD 15.4;  #  65 MHz
    set CLOCK_PERIOD 15.0;  #  66 MHz
    #set CLOCK_PERIOD 14.3;  #  70 MHz
    #set CLOCK_PERIOD 12.5;  #  80 MHz
    #set CLOCK_PERIOD 11.1;  #  90 MHz
    #set CLOCK_PERIOD 10.0;  # 100 MHz
    #set CLOCK_PERIOD  8.0;  # 125 MHz
}


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
set HADDR_DLY        [expr ($CLOCK_PERIOD/100) * 20]
set HPROT_DLY        [expr ($CLOCK_PERIOD/100) * 20]
set HREADY_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set HSMODE_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set HSIZE_DLY        [expr ($CLOCK_PERIOD/100) * 20]
set HTRANS_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set HWDATA_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set HWRITE_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set HSEL_DLY         [expr ($CLOCK_PERIOD/100) * 20]

# Outputs
set HRDATA_DLY       [expr ($CLOCK_PERIOD/100) * 70]
set HREADY_OUT_DLY   [expr ($CLOCK_PERIOD/100) * 70]
set HRESP_DLY        [expr ($CLOCK_PERIOD/100) * 70]


set_input_delay $HADDR_DLY                   -max -clock "hclk"   [get_ports haddr_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports haddr_i]

set_input_delay $HPROT_DLY                   -max -clock "hclk"   [get_ports hprot_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports hprot_i]

set_input_delay $HREADY_DLY                  -max -clock "hclk"   [get_ports hready_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports hready_i]

set_input_delay $HSMODE_DLY                  -max -clock "hclk"   [get_ports hsmode_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports hsmode_i]

set_input_delay $HPROT_DLY                   -max -clock "hclk"   [get_ports hprot_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports hprot_i]

set_input_delay $HTRANS_DLY                  -max -clock "hclk"   [get_ports htrans_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports htrans_i]

set_input_delay $HWDATA_DLY                  -max -clock "hclk"   [get_ports hwdata_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports hwdata_i]

set_input_delay $HWRITE_DLY                  -max -clock "hclk"   [get_ports hwrite_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports hwrite_i]

set_input_delay $HSEL_DLY                    -max -clock "hclk"   [get_ports hsel_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports hsel_i]


set_output_delay $HRDATA_DLY      -add_delay -max -clock "hclk"   [get_ports hrdata_o]
set_output_delay 0                           -min -clock "hclk"   [get_ports hrdata_o]

set_output_delay $HREADY_OUT_DLY  -add_delay -max -clock "hclk"   [get_ports hreadyout_o]
set_output_delay 0                           -min -clock "hclk"   [get_ports hreadyout_o]

set_output_delay $HRESP_DLY       -add_delay -max -clock "hclk"   [get_ports hresp_o]
set_output_delay 0                           -min -clock "hclk"   [get_ports hresp_o]


#=========================#
# REGISTER OUTPUT PORTS   #
#=========================#

set REGISTER_00_DLY      [expr ($CLOCK_PERIOD/100) * 75]
set REGISTER_01_DLY      [expr ($CLOCK_PERIOD/100) * 75]
set REGISTER_02_DLY      [expr ($CLOCK_PERIOD/100) * 75]
set REGISTER_03_DLY      [expr ($CLOCK_PERIOD/100) * 75]
set REGISTER_04_DLY      [expr ($CLOCK_PERIOD/100) * 75]
set REGISTER_05_DLY      [expr ($CLOCK_PERIOD/100) * 75]
set REGISTER_06_DLY      [expr ($CLOCK_PERIOD/100) * 75]
set REGISTER_07_DLY      [expr ($CLOCK_PERIOD/100) * 75]

set_output_delay $REGISTER_00_DLY     -add_delay -max -clock "hclk"   [get_ports register_00_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports register_00_o]

set_output_delay $REGISTER_01_DLY     -add_delay -max -clock "hclk"   [get_ports register_01_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports register_01_o]

set_output_delay $REGISTER_02_DLY     -add_delay -max -clock "hclk"   [get_ports register_02_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports register_02_o]

set_output_delay $REGISTER_03_DLY     -add_delay -max -clock "hclk"   [get_ports register_03_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports register_03_o]

set_output_delay $REGISTER_04_DLY     -add_delay -max -clock "hclk"   [get_ports register_04_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports register_04_o]

set_output_delay $REGISTER_05_DLY     -add_delay -max -clock "hclk"   [get_ports register_05_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports register_05_o]

set_output_delay $REGISTER_06_DLY     -add_delay -max -clock "hclk"   [get_ports register_06_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports register_06_o]

set_output_delay $REGISTER_07_DLY     -add_delay -max -clock "hclk"   [get_ports register_07_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports register_07_o]


#=========================#
# REGISTER INPUT PORTS    #
#=========================#

set REGISTER_08_DLY      [expr ($CLOCK_PERIOD/100) * 20]
set REGISTER_09_DLY      [expr ($CLOCK_PERIOD/100) * 20]
set REGISTER_10_DLY      [expr ($CLOCK_PERIOD/100) * 20]
set REGISTER_11_DLY      [expr ($CLOCK_PERIOD/100) * 20]
set REGISTER_12_DLY      [expr ($CLOCK_PERIOD/100) * 20]
set REGISTER_13_DLY      [expr ($CLOCK_PERIOD/100) * 20]
set REGISTER_14_DLY      [expr ($CLOCK_PERIOD/100) * 20]
set REGISTER_15_DLY      [expr ($CLOCK_PERIOD/100) * 20]

set_input_delay $REGISTER_08_DLY             -max -clock "hclk"   [get_ports register_08_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports register_08_i]

set_input_delay $REGISTER_09_DLY             -max -clock "hclk"   [get_ports register_09_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports register_09_i]

set_input_delay $REGISTER_10_DLY             -max -clock "hclk"   [get_ports register_10_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports register_10_i]

set_input_delay $REGISTER_11_DLY             -max -clock "hclk"   [get_ports register_11_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports register_11_i]

set_input_delay $REGISTER_12_DLY             -max -clock "hclk"   [get_ports register_12_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports register_12_i]

set_input_delay $REGISTER_13_DLY             -max -clock "hclk"   [get_ports register_13_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports register_13_i]

set_input_delay $REGISTER_14_DLY             -max -clock "hclk"   [get_ports register_14_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports register_14_i]

set_input_delay $REGISTER_15_DLY             -max -clock "hclk"   [get_ports register_15_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports register_15_i]


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
