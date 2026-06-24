#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    synthesis
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : synthesis.tcl
# Module Description : Top-level Design Compiler synthesis flow: read, compile,
#                      DFT insertion, reporting, and netlist dump.
#----------------------------------------------------------------------------

#=============================================================================#
#                                Configuration                                #
#=============================================================================#

# Enable/Disable DC_ULTRA option
set WITH_DC_ULTRA 1

# Enable/Disable DFT insertion
set WITH_DFT      1


#=============================================================================#
#                           Read technology library                           #
#=============================================================================#
source -echo -verbose ./library.tcl


#=============================================================================#
#                               Read design RTL                               #
#=============================================================================#
source -echo -verbose ./read.tcl


#=============================================================================#
#                           Set design constraints                            #
#=============================================================================#
source -echo -verbose ./constraints.tcl


#=============================================================================#
#              Set operating conditions & wire-load models                    #
#=============================================================================#

# Set operating conditions
set_operating_conditions -max $LIB_WC_OPCON -max_library $LIB_WC_NAME \
	                     -min $LIB_BC_OPCON -min_library $LIB_BC_NAME

# Set wire-load models
set_wire_load_mode top
set_wire_load_model -name $LIB_WIRE_LOAD -max -library $LIB_WC_NAME
set_wire_load_model -name $LIB_WIRE_LOAD -min -library $LIB_BC_NAME


#=============================================================================#
#                                Synthesize                                   #
#=============================================================================#

# Prevent assignment statements in the Verilog netlist.
set_fix_multiple_port_nets -all -buffer_constants

# Configuration
current_design $DESIGN_NAME
uniquify
set_max_area  0.0
set_flatten false
set_structure true -timing true -boolean true

# Verify constraints before synthesis
redirect -tee -file ./results/report.check_timing_pre {check_timing}

# Synthesis
if {$WITH_DC_ULTRA} {
    if {$WITH_DFT} {
	    compile_ultra -scan -no_autoungroup
    } else {
	    compile_ultra       -no_autoungroup
    }

    # Area optimization (run after compile)
    optimize_netlist -area

    # Check if timing met after area optimization
    if {[sizeof_collection [get_timing_paths -slack_lesser_than 0.0 -max_paths 1]] > 0} {
        puts "WARNING: Timing violated after area optimization. Re-optimizing for timing..."
        compile_ultra -incremental
    }

} else {
    if {$WITH_DFT} {
	compile       -scan -map_effort high -area_effort high
    } else {
	compile             -map_effort high -area_effort high
    }
}


#=============================================================================#
#                                DFT Insertion                                #
#=============================================================================#
if {$WITH_DFT} {

    # DFT Signal Type Definitions
    #set_dft_signal -view spec         -type ScanEnable  -port scan_enable_i -active_state 1
    #set_dft_signal -view existing_dft -type ScanEnable  -port scan_enable_i -active_state 1
    #set_dft_signal -view spec         -type Constant    -port scan_mode_i   -active_state 1
    #set_dft_signal -view existing_dft -type Constant    -port scan_mode_i   -active_state 1
    set_dft_signal -view existing_dft -type ScanClock   -port hclk_i        -timing [list 45 55]
    set_dft_signal -view existing_dft -type ScanClock   -port hclk_aon_i    -timing [list 45 55]
    set_dft_signal -view existing_dft -type ScanClock   -port clk_lf_i      -timing [list 45 55]
    set_dft_signal -view existing_dft -type Reset       -port hresetn_i     -active 0
    set_dft_signal -view existing_dft -type Reset       -port resetn_lf_i   -active 0

    # DFT Configuration
    set_dft_insertion_configuration -preserve_design_name true
    set_scan_configuration -style multiplexed_flip_flop
    set_scan_configuration -clock_mixing mix_clocks
    set_scan_configuration -chain_count 3

    # DFT Test Protocol Creation
    create_test_protocol

    # DFT Design Rule Check
    redirect -tee -file ./results/report.dft_drc           {dft_drc}
    redirect      -file ./results/report.dft_drc_verbose   {dft_drc -verbose}
    redirect      -file ./results/report.dft_drc_coverage  {dft_drc -coverage_estimate}
    redirect      -file ./results/report.dft_scan_config   {report_scan_configuration}
    redirect      -file ./results/report.dft_insert_config {report_dft_insertion_configuration}

    # Preview DFT insertion
    redirect -tee -file ./results/report.dft_preview       {preview_dft}
    redirect      -file ./results/report.dft_preview_all   {preview_dft -show all -test_points all}

    # DFT insertion
    insert_dft

    # DFT Incremental Compile
    if {$WITH_DC_ULTRA} {
	    compile_ultra -scan -incremental
    } else {
	    compile       -scan -incremental
    }

    # DFT Coverage estimate
    redirect      -file ./results/report.dft_drc_coverage  {dft_drc -coverage_estimate}
}

#=============================================================================#
#                            Reports generation                               #
#=============================================================================#

redirect -file ./results/report.timing         {check_timing}
redirect -file ./results/report.constraints    {report_constraints -all_violators -verbose}
redirect -file ./results/report.paths.max      {report_timing -path end  -delay max -max_paths 200 -nworst 2}
redirect -file ./results/report.full_paths.max {report_timing -path full -delay max -max_paths 5   -nworst 2}
redirect -file ./results/report.paths.min      {report_timing -path end  -delay min -max_paths 200 -nworst 2}
redirect -file ./results/report.full_paths.min {report_timing -path full -delay min -max_paths 5   -nworst 2}
redirect -file ./results/report.refs           {report_reference}
redirect -file ./results/report.area           {report_area}
redirect -file ./results/report.full_area      {report_area -hierarchy}

# Get clock period and frequency
set      CLK_FREQ     [expr {1000.0 / $CLOCK_PERIOD}]
set    ::CLK_FREQ_RPT         "\n"
append ::CLK_FREQ_RPT         "                ===========================================\n"
append ::CLK_FREQ_RPT [format "               |    Clock period: %.1f ns  (%.0f MHz)\n" $CLOCK_PERIOD $CLK_FREQ]
append ::CLK_FREQ_RPT         "                ===========================================\n\n"

# Add NAND2 size equivalent report to the area report file
set ::AREA_SUMMARY ""
if {[info exists NAND2_NAME]} {
    set nand2_area [get_attribute [get_lib_cell $LIB_WC_NAME/$NAND2_NAME] area]

    current_design $DESIGN_NAME
    redirect -variable design_area {report_area}
    regexp {Total cell area:\s+([^\n]+)\n} $design_area whole_match design_area

    set nand2_eq  [expr round($design_area/$nand2_area)]
    set design_area [expr round($design_area)]

    set fp [open "./results/report.area" a]
    puts $fp ""
    puts $fp "NAND2 equivalent cell area: $DESIGN_NAME --> $nand2_eq"
    close $fp

    append ::AREA_SUMMARY "\n"
    append ::AREA_SUMMARY "      =================================================================\n"
    append ::AREA_SUMMARY "     |                           AREA SUMMARY                          |\n"
    append ::AREA_SUMMARY "     |-----------------------------------------------------------------|\n"
    append ::AREA_SUMMARY "     |                                                                 |\n"
    append ::AREA_SUMMARY [format "%-5s| %-9s cell gate area: %-37s |\n" "" $NAND2_NAME $nand2_area]
    append ::AREA_SUMMARY "     |                                                                 |\n"
    append ::AREA_SUMMARY [format "%-5s| Total cell area: %-46s |\n" "" $design_area]
    append ::AREA_SUMMARY [format "%-5s| NAND2 eq.      : %-46s |\n" "" $nand2_eq]
    append ::AREA_SUMMARY "     |                                                                 |\n"
    append ::AREA_SUMMARY "      =================================================================\n"
    append ::AREA_SUMMARY "\n"
}

#=============================================================================#
#          Dump gate level netlist, final DDC file and Test protocol          #
#=============================================================================#
current_design $DESIGN_NAME

change_name -rules verilog -hierarchy

write -hierarchy -format verilog -output "./results/$DESIGN_NAME.gate.v"
write -hierarchy -format ddc     -output "./results/$DESIGN_NAME.ddc"

if {$WITH_DFT} {
    write_test_protocol          -output "./results/$DESIGN_NAME.spf"
}

#=============================================================================#
#                    PRINT SOME FINAL INTERESTING RESULTS                     #
#=============================================================================#

# Print area summary with NAND2 equivalent cell count
puts $::AREA_SUMMARY

# Print clock period and frequency
puts $::CLK_FREQ_RPT

if {$::env(NO_QUIT) == 0} {
    quit
}
