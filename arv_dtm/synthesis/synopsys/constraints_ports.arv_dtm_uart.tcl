#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    constraints_ports.arv_dtm_uart
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : constraints_ports.arv_dtm_uart.tcl
# Module Description : Clock, path groups, boundary I/O delays, reset
#                      false-path and DFT scan-clock/reset port lists for the
#                      UART DTM (arv_dtm_uart, or arv_dtm with DTM_TYPE=1).
#
#   arv_dtm_uart is SINGLE-clock: clk_i is the always-on oscillator and is
#   the DMI bus clock. The serial line is oversampled/synchronised inside the
#   block, so uart_rx_i has no tight boundary requirement.
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
#        UART SERIAL  (clk)         #
#==================================#

set UART_RX_DLY   [expr ($CLOCK_PERIOD/100) * 20]
set UART_TX_DLY   [expr ($CLOCK_PERIOD/100) * 60]

set_input_delay $UART_RX_DLY                  -max -clock "clk"    [get_ports uart_rx_i]
set_input_delay 0                             -min -clock "clk"    [get_ports uart_rx_i]

set_output_delay $UART_TX_DLY  -add_delay     -max -clock "clk"    [get_ports uart_tx_o]
set_output_delay 0                            -min -clock "clk"    [get_ports uart_tx_o]


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
