//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_ipdff
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_ipdff.v
// Module Description : Parameterizable enabled flip-flop primitive with build-time
//                      selectable reset architecture (async / sync).
//
//                      Shared across all aRVern system IPs (depend on arv_common).
//                      Functionally identical to the arvern CPU core's arv_dff, but
//                      deliberately named differently so the IP library stays self-
//                      contained and never collides with the core's primitive when
//                      both are elaborated together in an SoC.
//----------------------------------------------------------------------------
`default_nettype none

module  arv_ipdff #(
    parameter               WIDTH   = 1,             // register width
    parameter   [WIDTH-1:0] RST_VAL = {WIDTH{1'b0}}, // reset value
    parameter               ARST_EN = 1'b1           // 1=async active-low reset, 0=synchronous reset
) (
    input  wire             clk_i,                   // clock
    input  wire             rst_n_i,                 // active-low reset (async assert if ARST_EN=1, else sync)
    input  wire             en_i,                    // load enable (hold when 0)
    input  wire [WIDTH-1:0] d_i,                     // next-state
    output reg  [WIDTH-1:0] q_o                      // registered output
);

generate
    if (ARST_EN) begin : g_async_rst
        // Asynchronous active-low reset: reset test (rst_n_i) matches the negedge
        // term in the sensitivity list -> DC infers an async-reset flop.
        always @(posedge clk_i or negedge rst_n_i)
            if      (!rst_n_i) q_o <= RST_VAL;
            else if ( en_i   ) q_o <= d_i;
    end else begin : g_sync_rst
        // Synchronous reset: no async edge term; rst_n_i is sampled on the clock
        // edge -> DC infers a sync-reset flop.
        always @(posedge clk_i)
            if      (!rst_n_i) q_o <= RST_VAL;
            else if ( en_i   ) q_o <= d_i;
    end
endgenerate

endmodule // arv_ipdff

`default_nettype wire
