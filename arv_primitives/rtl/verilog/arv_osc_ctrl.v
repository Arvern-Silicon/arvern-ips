//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_osc_ctrl
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_osc_ctrl.v
// Module Description : Reference oscillator controller: turns a clock request
//                      into a stop sequence that consumers can survive.
//
//                      An IP clocked by an oscillator cannot detect that its own
//                      clock stopped -- there is no edge on which to notice. It
//                      has to be TOLD, early enough to act while it still has a
//                      clock. That is what clk_en_o is, and the whole point of
//                      this block is the one-edge gap:
//
//                        posedge N    : clk_en_o falls   (announce)
//                        posedge N+1  : osc_en_o  falls  (the oscillator stops)
//
//                      so exactly one clock edge is delivered with clk_en_o
//                      already low. A consumer whose flops have synchronous
//                      resets needs precisely that edge to reach its reset
//                      values before the clock disappears; with asynchronous
//                      resets the level alone is enough and the edge is free.
//                      Drive the aRVern ACLINT's hclk_aon_en_i from clk_en_o and
//                      its port contract is met by construction.
//
//                      A request arriving INSIDE that window cancels the stop
//                      rather than being stranded by it; section 2 has the why.
//
//                      ARST_EN IS FIXED AT 1 HERE, deliberately. Both flops are
//                      preset asynchronously by resetn_i and wake_i, and a wake
//                      arrives precisely when the oscillator is stopped -- there
//                      is no clock to sample it with. A synchronous preset would
//                      never take effect, so this is one of the few places in
//                      the library where the reset style is not a build option.
//                      The preset is released through a synchroniser on
//                      osc_clk_i, so its release is timed like any reset's.
//
//                      enable_i is sampled on osc_clk_i and so must be stable in
//                      that domain; wake_i is asynchronous by nature and is an
//                      asynchronous preset, not a datapath input.
//----------------------------------------------------------------------------
`default_nettype none

module  arv_osc_ctrl (

// OSCILLATOR
    input  wire osc_clk_i,    // The oscillator's own output, fed back
    output wire osc_en_o,     // To the oscillator: keep toggling

// CONTROL
    input  wire resetn_i,     // Asynchronous, active-low
    input  wire scan_mode_i,  // 1 = test mode: the wake path is ignored and the preset held inactive
    input  wire wake_i,       // Asynchronous wake request: restarts the oscillator with no clock available
    input  wire enable_i,     // Clock request, synchronous to osc_clk_i
    output wire clk_en_o      // "The clock is, or is about to be, running" -- falls one osc_clk_i edge before osc_en_o
);


//=============================================================================
// 1)  ASYNCHRONOUS PRESET
//=============================================================================
// Reset and wake both mean "run": the flops preset to 1 so the oscillator comes
// back without needing the clock it does not yet have. The preset asserts
// asynchronously and releases two osc_clk_i edges later. In test mode wake_i (a
// scanned flop in the consumer) is ignored, and the synchroniser output -- scan
// data itself -- is masked, so the preset never follows scan data.

wire wake_n;
wire wake_n_or_scan;
wire preset_raw_n;
wire preset_hold;
wire preset_hold_n;
wire preset_rel_n;
wire preset_n;

assign wake_n = ~wake_i;

arv_or #(.N(2)) u_wake_scan (
    .a_i ( {wake_n, scan_mode_i} ),
    .z_o (  wake_n_or_scan       )
);

arv_and #(.N(2)) u_preset_raw_n (
    .a_i ( {resetn_i, wake_n_or_scan} ),
    .z_o (  preset_raw_n              )
);

// preset_hold is set while the raw condition holds and clears two osc_clk_i edges
// after it lifts. The raw term asserts the preset directly and the synchroniser only
// delays its release, so the preset net falls with the raw condition from whatever
// state the synchroniser powers up in.
arv_synchronizer #(.W(1), .RST_VAL(1'b1), .ARST_EN(1'b1)) u_preset_sync (
    .clk_i   ( osc_clk_i    ),
    .rst_n_i ( preset_raw_n ),
    .async_i ( 1'b0         ),
    .sync_o  ( preset_hold  )
);

assign preset_hold_n = ~preset_hold;

arv_and #(.N(2)) u_preset_rel_n (
    .a_i ( {preset_raw_n, preset_hold_n} ),
    .z_o (  preset_rel_n                 )
);

arv_or #(.N(2)) u_preset_scan (
    .a_i ( {preset_rel_n, scan_mode_i} ),
    .z_o (  preset_n                   )
);


//=============================================================================
// 2)  ANNOUNCE, THEN STOP
//=============================================================================
// Two flops on the same clock. The first carries the request; the second trails
// it by one edge and is what actually stops the oscillator, so the gap between
// them is the edge the consumer gets to use.
//
// The second flop also sees enable_i directly. Without that it is a plain delayed
// copy of announce, and a clock request arriving INSIDE the announce window still
// stops the oscillator -- after which enable_i can never restart it, because
// there is no longer a clock to sample it with, and clk_en_o is left high over a
// dead clock. ORing enable_i in lets a late request cancel the stop while it is
// still cancellable, and changes nothing about a stop that is seen through: with
// enable_i low at both edges the sequence is unaltered.

wire announce;
wire run_d;
wire run;

arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(1'b1)) u_announce (
    .clk_i(osc_clk_i), .rst_n_i(preset_n), .en_i(1'b1), .d_i(enable_i), .q_o(announce));

assign run_d = announce | enable_i;

arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(1'b1)) u_run (
    .clk_i(osc_clk_i), .rst_n_i(preset_n), .en_i(1'b1), .d_i(run_d), .q_o(run));

assign clk_en_o  = announce;
assign osc_en_o  = run;

endmodule

`default_nettype wire
