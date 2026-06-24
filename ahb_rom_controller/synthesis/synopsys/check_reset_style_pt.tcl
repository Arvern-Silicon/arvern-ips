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
#   Reads a SYNTHESIZED ahb_rom_controller netlist and classifies every flop's reset as
#   asynchronous or synchronous, using `all_registers -async_pins`.
#   A flop owning an asynchronous preset/clear pin is async-reset; one with
#   none is sync-reset (reset folded into the data path).
#
#   Run:   pt_shell -f check_reset_style_pt.tcl
#
#   The expected reset style is auto-detected by grepping the RTL top's
#   ASYNC_RST_EN parameter default (the IP synthesis flow overrides no params,
#   so the RTL default is the value the netlist was built with): default
#   nonzero -> async, 0 -> sync. An EXPECT env var overrides; if detection
#   fails it falls back to async.
#----------------------------------------------------------------------------

proc check_reset_style {} {

    # ---- Design under check ------------------------------------------------
    # DESIGN_NAME / RESET_PORTS are the only IP-specific knobs in this script.
    set DESIGN_NAME "ahb_rom_controller"
    set RESET_PORTS {hresetn_i}

    set netlist "./results/${DESIGN_NAME}.gate.v"
    if {[info exists ::env(NETLIST)]} { set netlist $::env(NETLIST) }

    # Expected reset style, in priority order:
    #   1. explicit EXPECT env var (manual override);
    #   2. auto-detect from the RTL top's ASYNC_RST_EN parameter default (the value
    #      the netlist was synthesized with: nonzero -> async, 0 -> sync); else
    #   3. default to async.
    set expect ""
    set expect_src "default"
    if {[info exists ::env(EXPECT)]} {
        set expect     $::env(EXPECT)
        set expect_src "EXPECT env override"
    } else {
        # Auto-detect from the RTL top's ASYNC_RST_EN parameter DEFAULT. The IP
        # synthesis flow elaborates with default parameters (it overrides none),
        # so the RTL default is exactly what the netlist was built with:
        # default nonzero -> async, 0 -> sync.
        set rtl_top "../../rtl/verilog/${DESIGN_NAME}.v"
        if {[file exists $rtl_top]} {
            set fh [open $rtl_top r]
            set data [read $fh]
            close $fh
            foreach line [split $data "\n"] {
                if {![string match -nocase *parameter* $line]} { continue }
                set code [regsub {//.*$} $line ""]
                if {[regexp {ASYNC_RST_EN\s*=\s*([^;,/)=]+)} $code -> rawval]} {
                    set rawval [string trim $rawval]
                    regsub {^[0-9]+'[bBdDhHoO]} $rawval "" digits
                    set digits [string trim $digits]
                    if {$digits ne "" && [regexp {^[0_]+$} $digits]} {
                        set expect "sync"
                    } else {
                        set expect "async"
                    }
                    set expect_src "RTL default ($rtl_top: ASYNC_RST_EN=$rawval)"
                    break
                }
            }
        }
    }
    if {$expect eq ""} { set expect "async" }

    # ---- Technology library + netlist --------------------------------------
    # Reuse the synthesis library selection (gives LIB_WC_FILE; may be a list when
    # multiple Vt flavors are loaded -- the netlist uses both svt and lvt cells).
    source ./library.tcl
    set_app_var link_path "* $LIB_WC_FILE"

    read_verilog $netlist
    current_design $DESIGN_NAME
    link_design

    # ---- Classify ----------------------------------------------------------
    # Population for the reset-style policy = edge-triggered flip-flops only.
    # DFT scan insertion adds level-sensitive LOCKUP / hold latches at
    # clock-domain-crossing boundaries; those are intentionally un-reset (they
    # only hold during scan shift) and are NOT subject to the functional
    # reset-style policy. Classify flops only; the excluded latch count is
    # reported separately below.
    set ff      [all_registers -edge_triggered]
    set n_total [sizeof_collection $ff]
    set n_latch [sizeof_collection [all_registers -level_sensitive]]
    # Edge-triggered name set -- membership keeps the async tally to flops, so a
    # stray latch can never perturb the async/sync counts.
    array unset _ff
    array set   _ff {}
    foreach_in_collection c $ff { set _ff([get_object_name $c]) 1 }
    # A flop is genuinely async-reset only if its async pin is actually driven by the
    # reset. `all_registers -async_pins` also returns the async pin of async-CAPABLE
    # cells that synthesis chose for a SYNC flop and tied off (e.g. .SDN <- TIE cell);
    # those are functionally synchronous and must not be counted.
    #
    # Hierarchy-proof test: a real async reset pin lies in the transitive fanout of
    # a reset port; a tied-off pin is driven by a constant/tie cell and is NOT reached
    # by it. Build the union of every reset port's fanout once (handles buffer trees,
    # hierarchy crossings, and multiple reset domains), then test each async pin's
    # membership -- fast and robust.
    set apins      [all_registers -async_pins]
    set n_capable  0
    set async_names {}
    if {[sizeof_collection $apins] > 0} {
        set n_capable [sizeof_collection [get_cells -quiet -of_objects $apins]]
        # One-shot set of every pin reached by any reset port.
        array unset _rst_fo
        array set   _rst_fo {}
        foreach rp $RESET_PORTS {
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
                    lappend async_names [get_object_name $oc]
                }
            }
        }
    }
    set async_names [lsort -unique $async_names]
    set n_async [llength $async_names]
    set n_sync  [expr {$n_total - $n_async}]
    set n_tied  [expr {$n_capable - $n_async}]   ;# async-capable cells with the pin tied off

    # Offenders = registers whose reset style does NOT match EXPECT. Only ever built
    # on the FAIL path below (always non-empty there).
    #   expect async -> offenders lack a live async pin;
    #   expect sync  -> offenders have  a live async pin.
    if {$expect eq "async"} {
        set ok [expr {($n_total > 0) && ($n_async == $n_total)}]
        if {!$ok} {
            if {$n_async == 0} {
                set offenders $ff
            } else {
                set offenders [remove_from_collection $ff [get_cells $async_names]]
            }
        }
    } else {
        set ok [expr {($n_total > 0) && ($n_async == 0)}]
        if {!$ok} { set offenders [get_cells $async_names] }
    }

    # ---- Report ------------------------------------------------------------
    puts ""
    puts "#############  RESET-STYLE GATE-LEVEL CHECK (PrimeTime)  #############"
    puts [format "   design           : %s" $DESIGN_NAME]
    puts [format "   netlist          : %s" $netlist]
    puts [format "   reset port(s)    : %s" $RESET_PORTS]
    puts [format "   expected style   : %s   (from %s)" $expect $expect_src]
    puts [format "   total registers  : %d" $n_total]
    puts [format "   async-reset      : %d   (async pin driven by real logic)" $n_async]
    puts [format "   sync-reset       : %d" $n_sync]
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
        puts "   RESET-STYLE CHECK: PASS -- every flop is ${expect}-reset, as expected."
    } else {
        puts "   RESET-STYLE CHECK: FAIL -- mix does not match EXPECT=$expect (see counts)."
        if {[info exists offenders] && [sizeof_collection $offenders] > 0} {
            set n_off [sizeof_collection $offenders]
            set other [expr {$expect eq "async" ? "sync" : "async"}]
            puts "   ------------------------------------------------------------------"
            puts [format "   %d register(s) with the WRONG (%s) reset -- full list in" $n_off $other]
            puts "   ./results/report.reset_style_offenders.rpt :"
            # Console: list up to a cap so the transcript stays readable.
            set cap 50
            set shown 0
            foreach_in_collection c $offenders {
                if {$shown >= $cap} {
                    puts [format "      ... (%d more -- see the report file)" [expr {$n_off - $cap}]]
                    break
                }
                puts "      [get_object_name $c]"
                incr shown
            }
            # File: the complete list, regardless of the console cap.
            set fh [open "./results/report.reset_style_offenders.rpt" w]
            puts $fh "# Registers with WRONG reset style (expected $expect, these are $other)"
            puts $fh "# netlist: $netlist   count: $n_off"
            foreach_in_collection c $offenders { puts $fh [get_object_name $c] }
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
