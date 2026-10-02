//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_synchronizer
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_synchronizer.v
// Module Description : Parameterizable W-bit 2-FF synchronizer for crossing
//                      a level signal from one clock domain into clk_i.
//
//                      Reset architecture is selectable via ARST_EN, the reset value
//                      via RST_VAL (default 0; set all-1s for an idle-high line so it
//                      does not glitch low out of reset). With ARST_EN=0 only the
//                      first stage is reset, so sync_o reaches RST_VAL on the second
//                      edge: a synchronous reset must span two destination edges.
//                      Unlike the ordinary flops in this IP family, the synchronizer
//                      does NOT reuse arv_ipdff, because a synchronous-reset flop
//                      adds a 2:1 mux on the D pin -- and a mux on the SECOND stage
//                      (in the meta_q -> sync_q path) eats into the metastability
//                      settling window and degrades MTBF exponentially. The two
//                      reset styles are therefore hand-written (the sync-reset mux
//                      is kept on the first stage only).
//----------------------------------------------------------------------------
`default_nettype none

module  arv_synchronizer #(
    parameter           W       = 1,          // Width of the signal to synchronize
    parameter [W-1:0]   RST_VAL = {W{1'b0}},  // Reset value (e.g. all-1s for
                                              // an idle-high line, avoiding a reset-0 glitch)
    parameter           ARST_EN = 1'b1        // Reset style: 1=asynchronous, 0=synchronous
) (

// CLOCK & RESET (destination domain)
    input  wire         clk_i,               // Destination clock
    input  wire         rst_n_i,             // Active-low reset (async assert if ARST_EN=1, else sync)

// CROSSING
    input  wire [W-1:0] async_i,             // Source-domain signal (level)
    output wire [W-1:0] sync_o               // Synchronized output in clk_i domain
);


//=============================================================================
// 1)  2-FF SYNCHRONIZER  (meta flop -> sync flop)
//=============================================================================

reg [W-1:0] meta_q;                          // metastability-resolving first stage
reg [W-1:0] sync_q;                          // resynchronized second stage

assign sync_o = sync_q;

generate
    if (ARST_EN) begin : g_async_rst                // Asynchronous active-low reset on both stages

        always @(posedge clk_i or negedge rst_n_i)
            if (!rst_n_i) begin
                meta_q <= RST_VAL;
                sync_q <= RST_VAL;
            end else begin
                meta_q <= async_i;
                sync_q <= meta_q;
            end

    end else begin : g_sync_rst                     // Synchronous reset on the input stage only

        always @(posedge clk_i) begin
            meta_q <= rst_n_i ? async_i : RST_VAL;  // reset mux stays on the FIRST stage only
            sync_q <= meta_q;                       // (second stage kept mux-free for MTBF)
        end
    end
endgenerate


//=============================================================================
// 2)  PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if (W < 1) begin : CHECK_W
        initial $fatal(1, "arv_synchronizer: W (%0d) must be >= 1.", W);
    end
endgenerate
// pragma translate_on

endmodule // arv_synchronizer

`default_nettype wire
