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


# pclk_i and pclk_aon_i are the same physical clock at the SoC level (before
# and after the bus ICG); the input-path gate inside the IP is traced through.
create_clock -name     "pclk"                                 \
             -period   "$CLOCK_PERIOD"                        \
             -waveform "0 [expr $CLOCK_PERIOD/2]"             \
             [get_ports {pclk_i pclk_aon_i}]


##############################################################################
#                                                                            #
#                          CREATE PATH GROUPS                                #
#                                                                            #
##############################################################################

group_path -name REGOUT      -to   [all_outputs] 
group_path -name REGIN       -from [remove_from_collection [all_inputs] [get_ports {pclk_i pclk_aon_i}]]
group_path -name FEEDTHROUGH -from [remove_from_collection [all_inputs] [get_ports {pclk_i pclk_aon_i}]] -to [all_outputs]


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

foreach p {psel_i penable_i paddr_i pwrite_i pstrb_i pprot_i psmode_i} {
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


#===========================#
# PIN AND INTERRUPT OUTPUTS #
#===========================#

# All register outputs (irq_o / irq_any_o through the pending/enable AND-OR)
set GPIO_OUT_DLY     [expr ($CLOCK_PERIOD/100) * 75]
set IRQ_DLY          [expr ($CLOCK_PERIOD/100) * 60]

set_output_delay $GPIO_OUT_DLY    -add_delay -max -clock "pclk"   [get_ports gpio_o]
set_output_delay 0                           -min -clock "pclk"   [get_ports gpio_o]

set_output_delay $GPIO_OUT_DLY    -add_delay -max -clock "pclk"   [get_ports gpio_oe_o]
set_output_delay 0                           -min -clock "pclk"   [get_ports gpio_oe_o]

set_output_delay $GPIO_OUT_DLY    -add_delay -max -clock "pclk"   [get_ports gpio_ie_o]
set_output_delay 0                           -min -clock "pclk"   [get_ports gpio_ie_o]

set_output_delay $IRQ_DLY         -add_delay -max -clock "pclk"   [get_ports irq_o]
set_output_delay 0                           -min -clock "pclk"   [get_ports irq_o]

set_output_delay $IRQ_DLY         -add_delay -max -clock "pclk"   [get_ports irq_any_o]
set_output_delay 0                           -min -clock "pclk"   [get_ports irq_any_o]


#=============================#
# ALTERNATE-FUNCTION PORTS    #
#=============================#

# alt<k>_act_o are register outputs (ALT_EN / ALT_SEL); alt<k>_o_i and
# alt<k>_oe_i come from peripheral flops and pass through the pin mux to
# gpio_o / gpio_oe_o in the same cycle.
set ALT_ACT_DLY      [expr ($CLOCK_PERIOD/100) * 75]
set ALT_IN_DLY       [expr ($CLOCK_PERIOD/100) * 15]

foreach p {alt0_act_o alt1_act_o alt2_act_o alt3_act_o} {
    set_output_delay $ALT_ACT_DLY -add_delay -max -clock "pclk"   [get_ports $p]
    set_output_delay 0                       -min -clock "pclk"   [get_ports $p]
}
foreach p {alt0_o_i alt0_oe_i alt1_o_i alt1_oe_i alt2_o_i alt2_oe_i alt3_o_i alt3_oe_i} {
    set_input_delay $ALT_IN_DLY              -max -clock "pclk"   [get_ports $p]
    set_input_delay 0                        -min -clock "pclk"   [get_ports $p]
}


#=========================#
# PIN INPUTS              #
#=========================#

# SYNC_EN=1: gpio_i is asynchronous and lands only on the first synchroniser
# stage, so there is no path to time. SYNC_EN=0: gpio_i is synchronous to
# pclk_aon_i and feeds the input register directly.
set GPIO_IN_DLY      [expr ($CLOCK_PERIOD/100) * 20]
set GPIO_SYNC_MODE   [expr {![info exists RTL_PARAM_SYNC_EN] || $RTL_PARAM_SYNC_EN}]

if {$GPIO_SYNC_MODE} {
    set_false_path -from gpio_i
} else {
    set_input_delay $GPIO_IN_DLY             -max -clock "pclk"   [get_ports gpio_i]
    set_input_delay 0                        -min -clock "pclk"   [get_ports gpio_i]
}


#=========================#
# REMAINING OUTPUT PORTS  #
#=========================#

# pclk_en_o follows PSEL: it shares the input budget.
set PCLK_EN_DLY      [expr ($CLOCK_PERIOD/100) * 50]

set_output_delay $PCLK_EN_DLY     -add_delay -max -clock "pclk"   [get_ports pclk_en_o]
set_output_delay 0                           -min -clock "pclk"   [get_ports pclk_en_o]


#===============#
# FALSE PATHS   #
#===============#

# scan_mode_i is a test-mode constant: no functional path through it to time.
set_false_path -from scan_mode_i

# gpio_wake_o is a combinational function of the pads for an asynchronous,
# set-dominant input of the oscillator controller: not a timed path.
set_false_path -to gpio_wake_o

# THE RESET FALSE PATH IS CONDITIONAL ON THE RESET STYLE.
#
# With ASYNC_RST_EN=1 presetn_i drives asynchronous clear pins and there is
# nothing to time. With ASYNC_RST_EN=0 it is synchronous data feeding the
# flops' D-side mux and the reset term of pclk_en_o; false-pathing it would
# leave those paths unconstrained. Give it an input delay instead.
set PRESETN_DLY      [expr ($CLOCK_PERIOD/100) * 20]
set ASYNC_RST_MODE   [expr {![info exists RTL_PARAM_ASYNC_RST_EN] || $RTL_PARAM_ASYNC_RST_EN}]

if {$ASYNC_RST_MODE} {
    set_false_path -from presetn_i
} else {
    set_input_delay $PRESETN_DLY             -max -clock "pclk"   [get_ports presetn_i]
    set_input_delay 0                        -min -clock "pclk"   [get_ports presetn_i]
}
