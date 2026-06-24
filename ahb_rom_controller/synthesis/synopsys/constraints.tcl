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
group_path -name FEEDTHROUGH -from [remove_from_collection [all_inputs] [get_ports hclk_i]] -to [remove_from_collection [all_outputs] [get_ports rom_clk_o]]


##############################################################################
#                                                                            #
#                          BOUNDARY TIMINGS                                  #
#                                                                            #
##############################################################################

#================#
#     MEMORY     #
#================#

# Inputs
set MEM_DOUT_DLY    [expr ($CLOCK_PERIOD/100) * 20]

# Outputs
set MEM_ADDR_DLY    [expr ($CLOCK_PERIOD/100) * 70]
set MEM_CEN_DLY     [expr ($CLOCK_PERIOD/100) * 70]

set_input_delay  $MEM_DOUT_DLY               -max -clock "hclk"   [get_ports rom_dout_i]
set_input_delay  0                           -min -clock "hclk"   [get_ports rom_dout_i]

set_output_delay $MEM_ADDR_DLY    -add_delay -max -clock "hclk"   [get_ports rom_addr_o]
set_output_delay 0                           -min -clock "hclk"   [get_ports rom_addr_o]

set_output_delay $MEM_CEN_DLY     -add_delay -max -clock "hclk"   [get_ports rom_cen_o]
set_output_delay 0                           -min -clock "hclk"   [get_ports rom_cen_o]


#==========================#
#       AHB INTERFACE      #
#==========================#

# Inputs
set HADDR_DLY        [expr ($CLOCK_PERIOD/100) * 20]
set HREADY_DLY       [expr ($CLOCK_PERIOD/100) * 20]
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

set_input_delay $HREADY_DLY                  -max -clock "hclk"   [get_ports hready_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports hready_i]

set_input_delay $HSIZE_DLY                   -max -clock "hclk"   [get_ports hsize_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports hsize_i]

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
# REMAINING PORTS         #
#=========================#

# Outputs
set HCLK_EN_DLY          [expr ($CLOCK_PERIOD/100) * 75]

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
