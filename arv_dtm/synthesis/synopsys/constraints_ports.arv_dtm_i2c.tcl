#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    constraints_ports.arv_dtm_i2c
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : constraints_ports.arv_dtm_i2c.tcl
# Module Description : Clock, path groups, boundary I/O delays, reset
#                      false-path and DFT scan-clock/reset port lists for the
#                      I2C DTM (arv_dtm_i2c, or arv_dtm with DTM_TYPE=2).
#
#   arv_dtm_i2c is SINGLE-clock: clk_i is the always-on oscillator and is the
#   DMI bus clock. SCL/SDA are open-drain lines sampled through internal
#   synchronisers; sda_pd_o / scl_pd_o are the target's active-high pull-down
#   enables (open-drain drivers live at the pad, not in this block).
#----------------------------------------------------------------------------

##############################################################################
#                                                                            #
#                            CLOCK DEFINITION                                #
#                                                                            #
##############################################################################

set ::DTM_SYS_CLK "clk"

create_clock -name     "clk"                                  \
             -period   "$CLOCK_PERIOD"                        \
             -waveform "0 [expr $CLOCK_PERIOD/2]"             \
             [get_ports clk_i]


##############################################################################
#                                                                            #
#                          CREATE PATH GROUPS                                #
#                                                                            #
##############################################################################

dtm_path_groups clk_i


##############################################################################
#                                                                            #
#                          BOUNDARY TIMINGS                                  #
#                                                                            #
##############################################################################

#==================================#
#      I2C OPEN-DRAIN  (clk)        #
#==================================#

set SCL_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set SDA_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set SDA_PD_DLY    [expr ($CLOCK_PERIOD/100) * 60]
set SCL_PD_DLY    [expr ($CLOCK_PERIOD/100) * 60]

set_input_delay $SCL_DLY                      -max -clock "clk"    [get_ports scl_i]
set_input_delay 0                             -min -clock "clk"    [get_ports scl_i]

set_input_delay $SDA_DLY                      -max -clock "clk"    [get_ports sda_i]
set_input_delay 0                             -min -clock "clk"    [get_ports sda_i]

set_output_delay $SDA_PD_DLY   -add_delay     -max -clock "clk"    [get_ports sda_pd_o]
set_output_delay 0                            -min -clock "clk"    [get_ports sda_pd_o]

set_output_delay $SCL_PD_DLY   -add_delay     -max -clock "clk"    [get_ports scl_pd_o]
set_output_delay 0                            -min -clock "clk"    [get_ports scl_pd_o]

# I2C target address: quasi-static config input (SoC straps / config register).
# A port on arv_dtm_i2c only; the arv_dtm wrapper takes it as the I2C_ADDR
# parameter.
set I2C_ADDR_PORT [get_ports -quiet i2c_addr_i]
if {[sizeof_collection $I2C_ADDR_PORT] > 0} {
    set I2C_ADDR_DLY  [expr ($CLOCK_PERIOD/100) * 20]
    set_input_delay $I2C_ADDR_DLY             -max -clock "clk"    $I2C_ADDR_PORT
    set_input_delay 0                         -min -clock "clk"    $I2C_ADDR_PORT
}


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
#   Single clock, single active-low reset (dbgresetn_i, straight to the      #
#   flops). With ARST_EN=0 the reset enters the flops on the D side:         #
#   declared Reset, DRC would treat it as a clock on data pins (D10), so it  #
#   is held inactive as a test-mode constant instead.                        #
#                                                                            #
##############################################################################

set ::DFT_SCAN_CLOCKS {clk_i 45 55}
if {$DTM_ARST_EN} {
    set ::DFT_RESETS    {dbgresetn_i 0}
} else {
    set ::DFT_CONSTANTS {dbgresetn_i 1}
}
