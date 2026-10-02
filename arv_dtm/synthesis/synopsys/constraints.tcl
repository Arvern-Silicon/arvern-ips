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
# Module Description : Top-level timing constraints dispatcher.
#
#   The DTM transports do NOT share a clock topology: arv_dtm_jtag and
#   arv_dtm_cjtag are DUAL-clock (an external probe clock plus the always-on
#   system oscillator, asynchronous to each other), while arv_dtm_uart /
#   arv_dtm_i2c are SINGLE-clock (clk_i). Each transport therefore owns its
#   clock(s), CDC exceptions, path groups, boundary I/O delays, reset
#   false-paths AND the DFT port lists consumed by synthesis.tcl:
#     ::DFT_SCAN_CLOCKS  {<port> <timing_lo> <timing_hi> ...}
#     ::DFT_RESETS       {<port> <active_level> ...}     (declared Reset)
#     ::DFT_CONSTANTS    {<port> <active_state> ...}     (held in test mode)
#     ::DTM_SYS_CLK      name of the system (DMI) clock
#     ::DTM_TIED_OUTPUTS outputs driven by a constant (arv_dtm wrapper only)
#
#   This file fixes the default clock period (a library setup_*.tcl may
#   override CLOCK_PERIOD), defines the helpers shared by the ports files, and
#   sources the constraints_ports.<top>.tcl matching DESIGN_NAME. The arv_dtm
#   wrapper file in turn sources the transport file selected by DTM_TYPE.
#----------------------------------------------------------------------------

##############################################################################
#                                                                            #
#                          CLOCK PERIOD DEFAULT                              #
#                                                                            #
##############################################################################

# Clock period can be set by the library setup file (setup_*.tcl).
# If not already defined, use the default value below. The DTM is a slow
# debug-transport block; timing is not the constraint here, so a relaxed
# default is used.
if {![info exists CLOCK_PERIOD]} {
    #set CLOCK_PERIOD 100.0; #  10 MHz
    #set CLOCK_PERIOD 50.0;  #  20 MHz
    #set CLOCK_PERIOD 40.0;  #  25 MHz
    #set CLOCK_PERIOD 30.0;  #  33 MHz
    #set CLOCK_PERIOD 25.0;  #  40 MHz
    #set CLOCK_PERIOD 20.0;  #  50 MHz
    set CLOCK_PERIOD 15.0;  #  66 MHz
    #set CLOCK_PERIOD 12.5;  #  80 MHz
    #set CLOCK_PERIOD 10.0;  # 100 MHz
}


##############################################################################
#                                                                            #
#                        CONFIGURATION FROM rtl_params.tcl                   #
#                                                                            #
##############################################################################

# Reset style of the clk_i / hclk_i side (the probe-clock side is always
# asynchronous by design, TCK_ARST in arv_dtm_tap.v / arv_dtm_cjtag.v).
set DTM_ARST_EN [expr {![info exists RTL_PARAM_ARST_EN] || $RTL_PARAM_ARST_EN}]

# Defaults for the lists the ports files fill in.
set ::DFT_SCAN_CLOCKS  {}
set ::DFT_RESETS       {}
set ::DFT_CONSTANTS    {}
set ::DTM_SYS_CLK      ""
set ::DTM_TIED_OUTPUTS {}


##############################################################################
#                                                                            #
#                               HELPERS                                      #
#                                                                            #
##############################################################################

# DC releases differ on `set_max_delay -datapath_only`. Probe the option once;
# without it, a plain set_max_delay is equivalent here because every clock is
# ideal (no latency is modelled before CTS).
redirect -variable _smd_help {help -verbose set_max_delay}
set ::DTM_DATAPATH_ONLY [string match "*-datapath_only*" $_smd_help]
if {$::DTM_DATAPATH_ONLY} {
    puts "INFO: CDC budgets use set_max_delay -datapath_only"
} else {
    puts "INFO: set_max_delay has no -datapath_only in this release; CDC budgets use plain set_max_delay (ideal clocks)"
}

proc dtm_max_delay {value args} {
    if {$::DTM_DATAPATH_ONLY} {
        eval [list set_max_delay $value -datapath_only] $args
    } else {
        eval [list set_max_delay $value] $args
    }
}

# Registers whose full hierarchical name matches <glob>. Globs start with `*`
# so they match both a standalone top (u_tap/u_dmi_master/...) and the arv_dtm
# wrapper (g_<transport>.u_dtm/u_tap/...). An empty result on a crossing that
# must exist would silently drop its exception, so it is fatal.
proc dtm_regs {glob} {
    set regs [filter_collection [all_registers] "full_name =~ \"$glob\""]
    if {[sizeof_collection $regs] == 0} {
        puts "ERROR: constraints: no register matches '$glob' in $::DESIGN_NAME -- a CDC exception would be lost"
        exit 1
    }
    return $regs
}

# Asynchronous probe-clock <-> system-clock pair. NOT set_clock_groups and NOT
# a clock-to-clock false path: both outrank set_max_delay whatever its
# specificity, so they would silently void the explicit CDC budgets below.
# Instead every crossing is bounded to one period of its DESTINATION clock
# (setup), and only the hold side is cut. More specific -from/-to register
# budgets override this blanket bound.
proc dtm_async_pair {clk_a period_a clk_b period_b} {
    dtm_max_delay $period_b -from [get_clocks $clk_a] -to [get_clocks $clk_b]
    dtm_max_delay $period_a -from [get_clocks $clk_b] -to [get_clocks $clk_a]
    set_false_path -hold    -from [get_clocks $clk_a] -to [get_clocks $clk_b]
    set_false_path -hold    -from [get_clocks $clk_b] -to [get_clocks $clk_a]
}

# DMI payload crossing inside arv_dtm_dmi_master. Only the req/ack toggle
# levels go through synchronisers; the payload buses are held stable by the
# handshake and sampled directly by the destination domain, qualified by the
# synchronised toggle edge (>= 2 destination cycles later). Budget: one period
# of the destination clock, so the payload is settled well before the
# qualifying edge arrives.
#   request : u_req_latch (probe clock) -> u_hreq_addr/op/data (system clock)
#   response: u_rsp_data_h/u_rsp_stat_h (system clock) -> u_rdata_tck/u_cstat_tck (probe clock)
proc dtm_dmi_payload_cdc {probe_period sys_period} {
    set req_src [dtm_regs "*u_dmi_master/u_req_latch/*"]
    set req_dst [dtm_regs "*u_dmi_master/u_hreq_*"]
    set rsp_src [add_to_collection [dtm_regs "*u_dmi_master/u_rsp_data_h/*"] \
                                   [dtm_regs "*u_dmi_master/u_rsp_stat_h/*"]]
    set rsp_dst [add_to_collection [dtm_regs "*u_dmi_master/u_rdata_tck/*"] \
                                   [dtm_regs "*u_dmi_master/u_cstat_tck/*"]]
    dtm_max_delay $sys_period   -from $req_src -to $req_dst
    dtm_max_delay $probe_period -from $rsp_src -to $rsp_dst
}

# APB4 DMI master boundary, identical on every transport (system clock).
proc dtm_dmi_apb_io {clk period} {
    set out_dly [expr {($period/100.0) * 60}]
    set in_dly  [expr {($period/100.0) * 20}]
    set outs [get_ports {dmi_psel_o dmi_penable_o dmi_paddr_o dmi_pwrite_o dmi_pwdata_o dmi_pprot_o}]
    set ins  [get_ports {dmi_pready_i dmi_prdata_i dmi_pslverr_i}]
    set_output_delay $out_dly -add_delay -max -clock $clk $outs
    set_output_delay 0                   -min -clock $clk $outs
    set_input_delay  $in_dly             -max -clock $clk $ins
    set_input_delay  0                   -min -clock $clk $ins
}

# Standard path groups, excluding every clock port from the data sources.
proc dtm_path_groups {clk_ports} {
    set data_in [remove_from_collection [all_inputs] [get_ports $clk_ports]]
    group_path -name REGOUT      -to   [all_outputs]
    group_path -name REGIN       -from $data_in
    group_path -name FEEDTHROUGH -from $data_in -to [all_outputs]
}


##############################################################################
#                                                                            #
#              PER-TRANSPORT CLOCKS / PATH GROUPS / BOUNDARIES               #
#                                                                            #
##############################################################################

set DTM_PORTS_FILE "./constraints_ports.${DESIGN_NAME}.tcl"
if {![file exists $DTM_PORTS_FILE]} {
    puts "ERROR: unknown DESIGN_NAME '$DESIGN_NAME' -- no $DTM_PORTS_FILE"
    exit 1
}
source -echo -verbose $DTM_PORTS_FILE

if {$::DTM_SYS_CLK eq "" || [llength $::DFT_SCAN_CLOCKS] == 0} {
    puts "ERROR: $DTM_PORTS_FILE did not set ::DTM_SYS_CLK / ::DFT_SCAN_CLOCKS"
    exit 1
}

# DFT shift enable (JTAG / cJTAG tops and the wrapper). Functionally a static 0;
# it is also the chains' scan enable, so time it against the system clock.
# Crossings into the probe-clock domain are bounded by dtm_async_pair.
# scan_mode_i: static test-mode control.
set _scan_mode [get_ports -quiet scan_mode_i]
if {[sizeof_collection $_scan_mode] > 0} {
    set_false_path -from $_scan_mode
}
