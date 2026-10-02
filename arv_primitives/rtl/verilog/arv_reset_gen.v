//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_reset_gen
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_reset_gen.v
// Module Description : Reference reset generator for an aRVern SoC. Takes one
//                      raw asynchronous power-on reset and produces the three
//                      resets the platform needs, each ASSERTED asynchronously
//                      and RELEASED through a synchroniser on the clock that
//                      samples it.
//
//                        resetn_lf_o  LF / always-on domain. POR ONLY, released
//                                     on clk_lf_i. Drives the ACLINT MTIME
//                                     counter, so real time is monotonic across
//                                     a warm reset.
//                        dbgresetn_o  Debug domain. POR ONLY, released on
//                                     hclk_i, so a Debug Module survives the
//                                     warm reset it issues and the probe stays
//                                     attached.
//                        hresetn_o    Hart / system. POR | warm_reset_i,
//                                     released on hclk_i.
//
//                      The synchronisers are always asynchronous-reset: a reset
//                      generator must record the POR with no clock running (the
//                      crystal may not have started), so the reset style is not
//                      a build option here. Downstream flops keep their own.
//
//                      WHY resetn_lf_o LEADS hresetn_o (LF_GATE_EN=1)
//                        A synchronous-reset build reaches its reset values only
//                        on clock edges, so resetn_lf_o cannot release until
//                        clk_lf_i has actually run. Gating hresetn_o behind it
//                        makes three integration rules structural instead of
//                        advisory: the LF domain is initialised before any bus
//                        master can reach it; the first MTIME read cannot stall
//                        on a timebase that has not started; and no window
//                        exists in which the AHB domain is live while the LF
//                        domain is still in reset, which is when MTIME writes
//                        would be accepted on the bus and then dropped.
//
//                        The cost is a boot dependency: if clk_lf_i never runs,
//                        hresetn_o never releases. That is deliberate and
//                        diagnosable rather than silent -- dbgresetn_o is NOT
//                        gated, so a debugger still attaches and sees the hart
//                        held in reset. A platform that must boot without its
//                        low-frequency source sets LF_GATE_EN=0 and takes the
//                        ordering rules back as software requirements.
//
//                      warm_reset_i never reaches resetn_lf_o, in either
//                      setting: a warm reset that also reset MTIME would defeat
//                      the reason MTIME lives in the LF domain.
//----------------------------------------------------------------------------
`default_nettype none

module  arv_reset_gen #(
    parameter           LF_GATE_EN = 1'b1    // 1 = hold hresetn_o until resetn_lf_o has released; 0 = independent
) (

// SOURCE
    input  wire         porn_async_i,        // Raw asynchronous power-on reset, active-low. Not synchronised anywhere else
    input  wire         warm_reset_i,        // Active-high warm reset (e.g. dmcontrol.ndmreset). Already synchronous to hclk_i
    input  wire         scan_mode_i,         // 1 = test mode: every reset becomes porn_async_i, directly controllable from the pin

// CLOCKS
    input  wire         clk_lf_i,            // Low-frequency / always-on timebase clock
    input  wire         hclk_i,              // Always-on AHB-rate clock

// RESETS
    output wire         resetn_lf_o,         // LF domain      (POR only,   released on clk_lf_i)
    output wire         dbgresetn_o,         // Debug domain   (POR only,   released on hclk_i)
    output wire         hresetn_o            // Hart / system  (POR | warm, released on hclk_i)
);


//=============================================================================
// 1)  LF DOMAIN  --  POR only, released on clk_lf_i
//=============================================================================
// A reset synchroniser is a data synchroniser fed a constant 1: the flops clear
// asynchronously with porn_async_i and then have to shift that 1 through, which
// costs two clk_lf_i edges. That is exactly the "hold resetn_lf_i across at
// least two clk_lf_i edges" rule the ACLINT states, met by construction.

wire lf_rel;
wire lf_rel_or_scan;

arv_synchronizer #(.W(1), .RST_VAL(1'b0), .ARST_EN(1'b1)) u_lf_sync (
    .clk_i   ( clk_lf_i     ),
    .rst_n_i ( porn_async_i ),
    .async_i ( 1'b1         ),
    .sync_o  ( lf_rel       )
);

arv_or #(.N(2)) u_lf_rel_scan_bypass (
    .a_i ( {lf_rel, scan_mode_i} ),
    .z_o (  lf_rel_or_scan       )
);

arv_and #(.N(2)) u_resetn_lf (
    .a_i ( {porn_async_i, lf_rel_or_scan} ),
    .z_o (  resetn_lf_o                   )
);


//=============================================================================
// 2)  DEBUG DOMAIN  --  POR only, released on hclk_i
//=============================================================================
// Never gated by the LF domain: if the low-frequency source is dead this is the
// one reset that still releases, which is what turns a stalled boot into
// something a probe can observe.

wire dbg_rel;
wire dbg_rel_or_scan;

arv_synchronizer #(.W(1), .RST_VAL(1'b0), .ARST_EN(1'b1)) u_dbg_sync (
    .clk_i   ( hclk_i       ),
    .rst_n_i ( porn_async_i ),
    .async_i ( 1'b1         ),
    .sync_o  ( dbg_rel      )
);

arv_or #(.N(2)) u_dbg_rel_scan_bypass (
    .a_i ( {dbg_rel, scan_mode_i} ),
    .z_o (  dbg_rel_or_scan       )
);

arv_and #(.N(2)) u_dbgresetn (
    .a_i ( {porn_async_i, dbg_rel_or_scan} ),
    .z_o (  dbgresetn_o                    )
);


//=============================================================================
// 3)  HART / SYSTEM DOMAIN  --  POR | warm_reset_i, released on hclk_i
//=============================================================================
// The release input carries the warm reset and, when LF_GATE_EN=1, the LF
// domain's release. resetn_lf_o is a clk_lf_i-domain level: it crosses into
// hclk_i through its own synchroniser first, so the two terms combined in front
// of u_sys_sync are both hclk_i-synchronous.
//
// On a warm reset resetn_lf_o is already high, so the gate costs nothing there:
// the warm reset releases at hclk_i rate and never waits on the LF domain.

wire sys_allow;
wire sys_rel;
wire sys_rel_or_scan;

generate
    if (LF_GATE_EN != 0) begin : g_lf_gated             // hresetn_o trails resetn_lf_o
        wire lf_rel_h;
        arv_synchronizer #(.W(1), .RST_VAL(1'b0), .ARST_EN(1'b1)) u_lf_to_hclk (
            .clk_i   ( hclk_i       ),
            .rst_n_i ( porn_async_i ),
            .async_i ( resetn_lf_o  ),
            .sync_o  ( lf_rel_h     )
        );
        arv_and #(.N(2)) u_sys_allow (
            .a_i ( {~warm_reset_i, lf_rel_h} ),
            .z_o (  sys_allow                )
        );
    end else begin : g_lf_free                          // the two domains release independently
        assign sys_allow = ~warm_reset_i;
    end
endgenerate

arv_synchronizer #(.W(1), .RST_VAL(1'b0), .ARST_EN(1'b1)) u_sys_sync (
    .clk_i   ( hclk_i       ),
    .rst_n_i ( porn_async_i ),
    .async_i ( sys_allow    ),
    .sync_o  ( sys_rel      )
);

arv_or #(.N(2)) u_sys_rel_scan_bypass (
    .a_i ( {sys_rel, scan_mode_i} ),
    .z_o (  sys_rel_or_scan       )
);

arv_and #(.N(2)) u_hresetn (
    .a_i ( {porn_async_i, sys_rel_or_scan} ),
    .z_o (  hresetn_o                      )
);

endmodule

`default_nettype wire
