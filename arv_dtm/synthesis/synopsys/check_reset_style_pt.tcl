#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    check_reset_style_pt
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : check_reset_style_pt.tcl
# Module Description : Gate-level reset-style confirmation in PrimeTime.
#
#   Reads a SYNTHESIZED arv_dtm netlist and classifies every flop's reset as
#   asynchronous or synchronous, PER CLOCK DOMAIN. A flop owning an async
#   preset/clear pin driven from a reset port is async-reset; one without is
#   sync-reset (reset folded into the data path).
#
#   Run:   pt_shell -f check_reset_style_pt.tcl
#
#   Why per domain: ARST_EN only governs the system-clock side. The probe-clock
#   side of the JTAG and cJTAG transports (tck_i / tckc_i) is asynchronously
#   reset in every build (TCK_ARST), and so is the TAP's system-clock reset
#   conditioning u_tap/u_hclk_rst_sync + u_tap/u_hclk_rst_align (HCLK_ARST).
#   Expected result:
#     probe domain  : all async, always
#     system domain : async if ARST_EN=1; if ARST_EN=0 all sync EXCEPT those
#                     three flops (JTAG / cJTAG only). The exemption must match
#                     exactly three flops, so a stale glob cannot hide offenders.
#   A flop assigned to no clock domain is a failure.
#
#   Configuration, in priority order:
#     design  : DESIGN_NAME env var (run_check_reset_style -design), else
#               RTL_TOP of ./rtl_params.tcl (the last run_syn build), else
#               arv_dtm_jtag.
#     ARST_EN : EXPECT env var (async|sync, system domain only), else
#               RTL_PARAM_ARST_EN of ./rtl_params.tcl when it describes the
#               same top, else the RTL top's ARST_EN default, else async.
#     DTM_TYPE: RTL_PARAM_DTM_TYPE of ./rtl_params.tcl (arv_dtm wrapper), else 0.
#----------------------------------------------------------------------------

proc check_reset_style {} {

    # ---- Design under check ------------------------------------------------
    if {[file exists ./rtl_params.tcl]} { source ./rtl_params.tcl }

    if {[info exists ::env(DESIGN_NAME)] && $::env(DESIGN_NAME) ne ""} {
        set DESIGN_NAME $::env(DESIGN_NAME)
    } elseif {[info exists RTL_TOP]} {
        set DESIGN_NAME $RTL_TOP
    } else {
        set DESIGN_NAME "arv_dtm_jtag"
    }
    # rtl_params.tcl only describes the netlist when it names the same top.
    set params_apply [expr {[info exists RTL_TOP] && $RTL_TOP eq $DESIGN_NAME}]

    set transport $DESIGN_NAME
    set dtm_type  0
    if {$DESIGN_NAME eq "arv_dtm"} {
        if {$params_apply && [info exists RTL_PARAM_DTM_TYPE]} { set dtm_type $RTL_PARAM_DTM_TYPE }
        set transport [lindex {arv_dtm_jtag arv_dtm_uart arv_dtm_i2c arv_dtm_cjtag} $dtm_type]
        if {$transport eq ""} {
            puts "ERROR: arv_dtm DTM_TYPE '$dtm_type' is not 0..3"
            return 0
        }
    }

    # Per transport: probe clock port ("" = none), system clock port, reset
    # ports, and the system-domain flops that are async in every build.
    set sys_port clk_i
    set exempt_glob ""
    switch -- $transport {
        arv_dtm_jtag {
            set probe_port  tck_i
            set sys_port    [expr {$DESIGN_NAME eq "arv_dtm" ? "clk_i" : "hclk_i"}]
            set RESET_PORTS {trst_n_i dbgresetn_i}
            set exempt_glob "*u_hclk_rst_*/*"
        }
        arv_dtm_cjtag {
            set probe_port  tckc_i
            set RESET_PORTS {dbgresetn_i}
            set exempt_glob "*u_hclk_rst_*/*"
        }
        arv_dtm_uart -
        arv_dtm_i2c {
            set probe_port  ""
            set RESET_PORTS {dbgresetn_i}
        }
        default {
            puts "ERROR: unknown design '$DESIGN_NAME'"
            return 0
        }
    }
    set n_exempt_expected 3

    set netlist "./results/${DESIGN_NAME}.gate.v"
    if {[info exists ::env(NETLIST)]} { set netlist $::env(NETLIST) }

    # ---- Expected system-domain reset style --------------------------------
    set expect ""
    set expect_src "default"
    if {[info exists ::env(EXPECT)] && $::env(EXPECT) ne ""} {
        set expect     $::env(EXPECT)
        set expect_src "EXPECT env override"
    } elseif {$params_apply} {
        # A config without an ARST_EN override was built with the RTL default.
        if {[info exists RTL_PARAM_ARST_EN]} {
            set expect     [expr {$RTL_PARAM_ARST_EN ? "async" : "sync"}]
            set expect_src "./rtl_params.tcl ($RTL_CONFIG_LABEL: ARST_EN=$RTL_PARAM_ARST_EN)"
        }
    }
    if {$expect eq ""} {
        set rtl_top "../../rtl/verilog/${DESIGN_NAME}.v"
        if {[file exists $rtl_top]} {
            set fh [open $rtl_top r]
            set data [read $fh]
            close $fh
            foreach line [split $data "\n"] {
                if {![string match -nocase *parameter* $line]} { continue }
                set code [regsub {//.*$} $line ""]
                if {[regexp {\mARST_EN\s*=\s*([^;,/)=]+)} $code -> rawval]} {
                    set rawval [string trim $rawval]
                    regsub {^[0-9]+'[bBdDhHoO]} $rawval "" digits
                    set digits [string trim $digits]
                    if {$digits ne "" && [regexp {^[0_]+$} $digits]} {
                        set expect "sync"
                    } else {
                        set expect "async"
                    }
                    set expect_src "RTL default ($rtl_top: ARST_EN=$rawval)"
                    break
                }
            }
        }
    }
    if {$expect eq ""} { set expect "async" }
    if {$expect ne "async" && $expect ne "sync"} {
        puts "ERROR: EXPECT must be async or sync (got '$expect')"
        return 0
    }

    # ---- Technology library + netlist --------------------------------------
    # Reuse the synthesis library selection (gives LIB_WC_FILE; may be a list when
    # multiple Vt flavors are loaded -- the netlist uses both svt and lvt cells).
    source ./library.tcl
    set_app_var link_path "* $LIB_WC_FILE"

    read_verilog $netlist
    current_design $DESIGN_NAME
    link_design

    # Clocks, so every flop can be assigned to a domain.
    set domains {}
    if {$probe_port ne ""} {
        create_clock -name probe_clk -period 100 [get_ports $probe_port]
        lappend domains [list probe_clk $probe_port async "always async (TCK_ARST)"]
    }
    create_clock -name sys_clk -period 10 [get_ports $sys_port]
    lappend domains [list sys_clk $sys_port $expect $expect_src]

    # ---- Classify ----------------------------------------------------------
    # Population = edge-triggered flip-flops only. DFT scan insertion adds
    # level-sensitive lockup latches at clock / edge boundaries; they are
    # intentionally un-reset and reported separately.
    set ff      [all_registers -edge_triggered]
    set n_total [sizeof_collection $ff]
    set n_latch [sizeof_collection [all_registers -level_sensitive]]
    array unset _ff
    array set   _ff {}
    foreach_in_collection c $ff { set _ff([get_object_name $c]) 1 }

    # A flop is async-reset only if its async pin is driven by a reset port.
    # `all_registers -async_pins` also returns the tied-off async pin of an
    # async-capable cell used as a sync flop; those are not in the fanout of any
    # reset port and are not counted.
    set apins     [all_registers -async_pins]
    set n_capable 0
    array unset _async
    array set   _async {}
    if {[sizeof_collection $apins] > 0} {
        set n_capable [sizeof_collection [get_cells -quiet -of_objects $apins]]
        array unset _rst_fo
        array set   _rst_fo {}
        # scan_mode_i is a fanout SEED, not a reset port: every internally
        # generated reset of the JTAG / cJTAG front-ends (reset-synchroniser
        # outputs) is ORed with it, so its fanout reaches those async pins
        # combinationally, without relying on a CDN->Q arc through the
        # synchroniser. It cannot mark a tied-off or D-side pin as async.
        foreach rp [concat $RESET_PORTS scan_mode_i] {
            set rport [get_ports -quiet $rp]
            if {[sizeof_collection $rport] == 0} { continue }
            foreach_in_collection p [all_fanout -quiet -flat -from $rport] {
                set _rst_fo([get_object_name $p]) 1
            }
        }
        foreach_in_collection ap $apins {
            if {[info exists _rst_fo([get_object_name $ap])]} {
                set oc [get_cells -quiet -of_objects $ap]
                if {[sizeof_collection $oc] > 0 && [info exists _ff([get_object_name $oc])]} {
                    set _async([get_object_name $oc]) 1
                }
            }
        }
    }
    set n_async_all [array size _async]
    set n_tied      [expr {$n_capable - $n_async_all}]

    # Per domain.
    set ok 1
    set offenders {}
    array unset _seen
    array set   _seen {}
    set rows {}
    foreach d $domains {
        foreach {clk port dexp dsrc} $d break
        set n 0; set na 0; set ns 0; set nx 0
        foreach_in_collection c [all_registers -edge_triggered -clock $clk] {
            set name [get_object_name $c]
            if {![info exists _ff($name)] || [info exists _seen($name)]} { continue }
            set _seen($name) 1
            incr n
            set is_async [info exists _async($name)]
            if {$is_async} { incr na } else { incr ns }
            set is_exempt [expr {$clk eq "sys_clk" && $exempt_glob ne "" && [string match $exempt_glob $name]}]
            if {$is_exempt} {
                incr nx
                # Exempt flops are async in every build.
                if {!$is_async} { lappend offenders "$name  (exempt synchroniser, expected async)"; set ok 0 }
                continue
            }
            if {($dexp eq "async") != $is_async} {
                lappend offenders "$name  ($port domain, expected $dexp)"
                set ok 0
            }
        }
        if {$n == 0} { set ok 0 }
        if {$clk eq "sys_clk" && $exempt_glob ne "" && $nx != $n_exempt_expected} {
            puts [format "   ERROR: exemption '%s' matched %d flop(s), expected %d" $exempt_glob $nx $n_exempt_expected]
            set ok 0
        }
        lappend rows [list $port $dexp $dsrc $n $na $ns $nx]
    }
    set n_unassigned 0
    foreach name [array names _ff] {
        if {![info exists _seen($name)]} {
            incr n_unassigned
            lappend offenders "$name  (no clock domain)"
            set ok 0
        }
    }

    # ---- Report ------------------------------------------------------------
    puts ""
    puts "#############  RESET-STYLE GATE-LEVEL CHECK (PrimeTime)  #############"
    puts [format "   design           : %s" $DESIGN_NAME]
    if {$DESIGN_NAME eq "arv_dtm"} {
        puts [format "   transport        : %s (DTM_TYPE=%s)" $transport $dtm_type]
    }
    puts [format "   netlist          : %s" $netlist]
    puts [format "   reset port(s)    : %s" $RESET_PORTS]
    puts [format "   total registers  : %d   (async %d, sync %d)" $n_total $n_async_all [expr {$n_total - $n_async_all}]]
    foreach r $rows {
        foreach {port dexp dsrc n na ns nx} $r break
        puts [format "   %-7s domain    : %4d flops  async %4d  sync %4d   expect %-5s (%s)" $port $n $na $ns $dexp $dsrc]
        if {$nx > 0} {
            puts [format "                      %d of them exempt, async by design (%s)" $nx $exempt_glob]
        }
    }
    if {$n_unassigned > 0} {
        puts [format "   no clock domain  : %d flop(s)" $n_unassigned]
    }
    if {$n_tied > 0} {
        puts [format "   note             : %d async-capable cell(s) have the async pin tied off" $n_tied]
        puts        "                      (functionally synchronous -- not counted as async)"
    }
    if {$n_latch > 0} {
        puts [format "   excluded latches : %d level-sensitive cell(s) excluded from the policy" $n_latch]
        puts        "                      (DFT scan lockup / hold latches -- intentionally un-reset)"
    }
    puts "   ------------------------------------------------------------------"
    if {$ok} {
        puts "   RESET-STYLE CHECK: PASS -- every domain matches its expected style."
    } else {
        puts "   RESET-STYLE CHECK: FAIL -- see the per-domain counts above."
        set n_off [llength $offenders]
        if {$n_off > 0} {
            puts "   ------------------------------------------------------------------"
            puts [format "   %d register(s) with the WRONG reset -- full list in" $n_off]
            puts "   ./results/report.reset_style_offenders.rpt :"
            set cap 50
            set shown 0
            foreach o $offenders {
                if {$shown >= $cap} {
                    puts [format "      ... (%d more -- see the report file)" [expr {$n_off - $cap}]]
                    break
                }
                puts "      $o"
                incr shown
            }
            set fh [open "./results/report.reset_style_offenders.rpt" w]
            puts $fh "# Registers with the WRONG reset style"
            puts $fh "# netlist: $netlist   count: $n_off"
            foreach o $offenders { puts $fh $o }
            close $fh
        }
    }
    puts "#####################################################################"
    puts ""

    return $ok
}

# Consume the proc's return value in an if (which itself returns nothing) so
# pt_shell doesn't echo a bare "1"/"0"; use it to set the shell exit status.
if {[check_reset_style]} { exit 0 } else { exit 1 }
