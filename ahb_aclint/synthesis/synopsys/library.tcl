#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    library
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : library.tcl
# Module Description : Technology library selection and operating-conditions
#                      setup. Sourced by synthesis.tcl.
#----------------------------------------------------------------------------

##############################################################################
#                                                                            #
#                            SPECIFY LIBRARIES                               #
#                                                                            #
##############################################################################

# Select active library flavor from environment (set by run_syn -lib <flavor>)
if {[info exists ::env(LIB_FLAVOR)]} {
    set LIB_FLAVOR $::env(LIB_FLAVOR)
} else {
    set LIB_FLAVOR "lib_default"
}

# Source library setup
source "./libraries/setup_${LIB_FLAVOR}.tcl"

# Extract variables from selected namespace into global scope
set LIB_WC_FILE   [set ${LIB_FLAVOR}::LIB_WC_FILE]
set LIB_WC_NAME   [set ${LIB_FLAVOR}::LIB_WC_NAME]
set LIB_BC_FILE   [set ${LIB_FLAVOR}::LIB_BC_FILE]
set LIB_BC_NAME   [set ${LIB_FLAVOR}::LIB_BC_NAME]
set LIB_WC_OPCON  [set ${LIB_FLAVOR}::LIB_WC_OPCON]
set LIB_BC_OPCON  [set ${LIB_FLAVOR}::LIB_BC_OPCON]
set LIB_WIRE_LOAD [set ${LIB_FLAVOR}::LIB_WIRE_LOAD]
set NAND2_NAME    [set ${LIB_FLAVOR}::NAND2_NAME]

# Optional SRAM library (not used by this IP, but kept compatible with
# library setup files that are shared with chip-level flows)
if {[info exists ${LIB_FLAVOR}::SRAM_LIB_FILE]} {
    set SRAM_LIB_FILE [set ${LIB_FLAVOR}::SRAM_LIB_FILE]
} else {
    set SRAM_LIB_FILE [list]
}
if {[info exists ${LIB_FLAVOR}::SRAM_VERILOG_WRAPPER]} {
    set SRAM_VERILOG_WRAPPER [set ${LIB_FLAVOR}::SRAM_VERILOG_WRAPPER]
} else {
    set SRAM_VERILOG_WRAPPER [list]
}

# Optional clock period override from library setup
if {[info exists ${LIB_FLAVOR}::CLOCK_PERIOD]} {
    set CLOCK_PERIOD [set ${LIB_FLAVOR}::CLOCK_PERIOD]
}

# Set library (LIB_WC_FILE / LIB_BC_FILE may be lists when multiple Vt variants are loaded)
set target_library [concat   $LIB_WC_FILE              $SRAM_LIB_FILE]
set link_library   [concat * $LIB_WC_FILE $LIB_BC_FILE $SRAM_LIB_FILE]
foreach wc_file $LIB_WC_FILE bc_file $LIB_BC_FILE {
    set_min_library $wc_file -min_version $bc_file
}
