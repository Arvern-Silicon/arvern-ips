namespace eval lib_example {

    # Worst case library
    variable LIB_WC_FILE   "<YOUR WORST CASE LIBRARY FILE>.db"
    variable LIB_WC_NAME   "<YOUR WORST CASE LIBRARY NAME>"

    # Best case library
    variable LIB_BC_FILE   "<YOUR BEST CASE LIBRARY FILE>.db"
    variable LIB_BC_NAME   "<YOUR BEST CASE LIBRARY NAME>"

    # Operating conditions
    variable LIB_WC_OPCON  "<YOUR WORST CASE OP-CON>"
    variable LIB_BC_OPCON  "<YOUR BEST CASE OP-CON>"

    # Wire-load model
    variable LIB_WIRE_LOAD "<YOUR WIRELOAD MODEL>"

    # Nand2 gate name for area size calculation
    variable NAND2_NAME    "<YOUR SMALLEST NAND2 CELL NAME>"

    # SRAM library
    variable SRAM_LIB_FILE "<YOUR WORST CASE SRAM LIBRARY FILE>.db"

    # SRAM wrapper verilog file
    variable SRAM_VERILOG_WRAPPER  "<YOUR PATH TO THE SRAM WRAPPER VERILOG FILE>.v"

    # Clock period (ns) — overrides constraints.tcl value
    variable CLOCK_PERIOD  <YOU TARGET CLOCK PERIOD IN NS>;  # e.g., 10.0 for 100 MHz
}
