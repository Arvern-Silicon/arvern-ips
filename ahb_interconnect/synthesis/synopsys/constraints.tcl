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
# Module Description : Top-level timing constraints: clock, path groups, and
#                      fabric-specific boundary I/O delays (sourced from the
#                      constraints_ports.<fabric>.tcl matching DESIGN_NAME).
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

if {$DESIGN_NAME eq "ahb_interconnect_generic"} {

   source -echo -verbose ./constraints_ports.generic.tcl

} elseif {$DESIGN_NAME eq "ahb_interconnect_hiperf"} {

   source -echo -verbose ./constraints_ports.hiperf.tcl

} elseif {$DESIGN_NAME eq "ahb_interconnect_fused"} {

   source -echo -verbose ./constraints_ports.fused.tcl

} else {

   puts "ERROR: unknown DESIGN_NAME '$DESIGN_NAME' — no boundary-timings file"
}
