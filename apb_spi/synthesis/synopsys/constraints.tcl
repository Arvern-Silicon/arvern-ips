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


# pclk_i is the APB clock and the SPI timebase: every SPI output is a flop on
# it. spi_sck_o is a generated clock of pclk_i for the devices it drives; that
# is the SoC's constraint (HALF is a register), here it is timed as a data
# output.
create_clock -name     "pclk"                                 \
             -period   "$CLOCK_PERIOD"                        \
             -waveform "0 [expr $CLOCK_PERIOD/2]"             \
             [get_ports pclk_i]


##############################################################################
#                                                                            #
#                          CREATE PATH GROUPS                                #
#                                                                            #
##############################################################################

group_path -name REGOUT      -to   [all_outputs] 
group_path -name REGIN       -from [remove_from_collection [all_inputs] [get_ports pclk_i]]
group_path -name FEEDTHROUGH -from [remove_from_collection [all_inputs] [get_ports pclk_i]] -to [all_outputs]


##############################################################################
#                                                                            #
#                          BOUNDARY TIMINGS                                  #
#                                                                            #
##############################################################################

#==========================#
#      APB4 COMPLETER      #
#==========================#

# Inputs: the requester (ahb_apb_bridge) drives the control signals from flops
# and passes HWDATA through to PWDATA, keeping 70% / 40% of the cycle for the
# completer: they arrive at 30% / 60%.
set APB_CTL_DLY      [expr ($CLOCK_PERIOD/100) * 30]
set PWDATA_DLY       [expr ($CLOCK_PERIOD/100) * 60]

foreach p {psel_i penable_i paddr_i pwrite_i pstrb_i pprot_i psmode_i pmaster_i} {
    set_input_delay $APB_CTL_DLY             -max -clock "pclk"   [get_ports $p]
    set_input_delay 0                        -min -clock "pclk"   [get_ports $p]
}
set_input_delay $PWDATA_DLY                  -max -clock "pclk"   [get_ports pwdata_i]
set_input_delay 0                            -min -clock "pclk"   [get_ports pwdata_i]

# Outputs: the requester registers the response and keeps 60% of the cycle
# for the completer's read mux and error decode (40% left on the output).
set APB_RSP_DLY      [expr ($CLOCK_PERIOD/100) * 40]

foreach p {prdata_o pready_o pslverr_o} {
    set_output_delay $APB_RSP_DLY -add_delay -max -clock "pclk"   [get_ports $p]
    set_output_delay 0                       -min -clock "pclk"   [get_ports $p]
}


#===============================#
# SPI AND INTERRUPT OUTPUTS     #
#===============================#

# Flop outputs: the SPI pins go to pads (75% of the cycle left), irq_o is an
# AND-OR of registers for the PLIC gateway.
set SPI_OUT_DLY      [expr ($CLOCK_PERIOD/100) * 75]
set IRQ_DLY          [expr ($CLOCK_PERIOD/100) * 60]

foreach p {spi_sck_o spi_cs_o spi_io_o spi_io_oe_o} {
    set_output_delay $SPI_OUT_DLY -add_delay -max -clock "pclk"   [get_ports $p]
    set_output_delay 0                       -min -clock "pclk"   [get_ports $p]
}
set_output_delay $IRQ_DLY         -add_delay -max -clock "pclk"   [get_ports irq_o]
set_output_delay 0                           -min -clock "pclk"   [get_ports irq_o]


#=========================#
# SPI INPUTS              #
#=========================#

# spi_io_i lands only on the first synchroniser stages: its timing is the
# board-level round-trip budget (doc "Receive timing"), not a synchronous
# path. (With RX_EN = 0 the inputs are unconnected.)
set_false_path -from [get_ports spi_io_i*]


#=========================#
# REMAINING OUTPUT PORTS  #
#=========================#

# pclk_en_o is PSEL OR registers: it shares the input budget.
set PCLK_EN_DLY      [expr ($CLOCK_PERIOD/100) * 50]

set_output_delay $PCLK_EN_DLY     -add_delay -max -clock "pclk"   [get_ports pclk_en_o]
set_output_delay 0                           -min -clock "pclk"   [get_ports pclk_en_o]


#===============#
# FALSE PATHS   #
#===============#

# THE RESET FALSE PATH IS CONDITIONAL ON THE RESET STYLE.
#
# With ASYNC_RST_EN=1 presetn_i drives asynchronous clear pins and there is
# nothing to time. With ASYNC_RST_EN=0 it is synchronous data feeding the
# flops' D-side mux; false-pathing it would leave those paths unconstrained.
# Give it an input delay instead.
set PRESETN_DLY      [expr ($CLOCK_PERIOD/100) * 20]
set ASYNC_RST_MODE   [expr {![info exists RTL_PARAM_ASYNC_RST_EN] || $RTL_PARAM_ASYNC_RST_EN}]

if {$ASYNC_RST_MODE} {
    set_false_path -from presetn_i
} else {
    set_input_delay $PRESETN_DLY             -max -clock "pclk"   [get_ports presetn_i]
    set_input_delay 0                        -min -clock "pclk"   [get_ports presetn_i]
}
