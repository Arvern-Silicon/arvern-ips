#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    read
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : read.tcl
# Module Description : Read, analyze, elaborate and link the RTL design.
#                      DESIGN_NAME selects the synthesis top among:
#                        - ahb_interconnect_generic
#                        - ahb_interconnect_hiperf
#                        - ahb_interconnect_fused (default)
#----------------------------------------------------------------------------

##############################################################################
#                                                                            #
#                               READ DESIGN RTL                              #
#                                                                            #
##############################################################################

set DESIGN_NAME      "ahb_interconnect_fused"

if {[info exists ::env(DESIGN_NAME)]} {
    set DESIGN_NAME $::env(DESIGN_NAME)
}

# RTL_SOURCE_FILES (+ RTL_INCDIRS) come from submit_syn.tcl, auto-generated
# by `flatten_filelist.py --format tcl` from rtl/verilog/filelist.f (the
# single source of truth shared with the simulation flow).  All three
# variant tops (generic / hiperf / fused) compile from the same RTL set;
# DESIGN_NAME picks which one is elaborated.
source ./submit_syn.tcl

set_svf ./results/$DESIGN_NAME.svf
define_design_lib WORK -path ./WORK
analyze -format verilog $RTL_SOURCE_FILES

elaborate $DESIGN_NAME
link


# Check design structure after reading verilog
current_design $DESIGN_NAME
redirect ./results/report.check {check_design}
