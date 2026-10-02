//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_ipdff_sinit
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_ipdff_sinit.v
// Module Description : arv_ipdff plus a synchronous init: on top of the primary
//                      reset (rst_n_i, async/sync per ARST_EN), an active-high
//                      sinit_i synchronously reloads RST_VAL. Lets a datapath-
//                      derived soft reset ride clock-sampled logic (scannable,
//                      glitch-immune) instead of a gated async reset.
//
//                      The IP-library twin of the arvern CPU core's
//                      arv_dff_sinit (kept separate so the IP library stays self-
//                      contained), extended with CLK_NEGEDGE like arv_ipdff.
//----------------------------------------------------------------------------
`default_nettype none

module  arv_ipdff_sinit #(
    parameter               WIDTH       = 1,             // register width
    parameter   [WIDTH-1:0] RST_VAL     = {WIDTH{1'b0}}, // reset / init value
    parameter               ARST_EN     = 1'b1,          // 1=async active-low reset, 0=synchronous reset
    parameter               CLK_NEGEDGE = 1'b0           // clock edge: 0=posedge (default), 1=negedge
) (
    input  wire             clk_i,                       // clock (edge selected by CLK_NEGEDGE)
    input  wire             rst_n_i,                     // active-low reset (async assert if ARST_EN=1, else sync)
    input  wire             sinit_i,                     // active-high synchronous init to RST_VAL
    input  wire             en_i,                        // load enable (hold when 0)
    input  wire [WIDTH-1:0] d_i,                         // next-state
    output reg  [WIDTH-1:0] q_o                          // registered output
);

generate
    if (ARST_EN && !CLK_NEGEDGE) begin : g_async_rst_pos           // Async reset, posedge clock

        always @(posedge clk_i or negedge rst_n_i)
            if      (!rst_n_i) q_o <= RST_VAL;
            else if ( sinit_i) q_o <= RST_VAL;
            else if ( en_i   ) q_o <= d_i;

    end else if (ARST_EN && CLK_NEGEDGE) begin : g_async_rst_neg   // Async reset, negedge clock

        always @(negedge clk_i or negedge rst_n_i)
            if      (!rst_n_i) q_o <= RST_VAL;
            else if ( sinit_i) q_o <= RST_VAL;
            else if ( en_i   ) q_o <= d_i;

    end else if (!ARST_EN && !CLK_NEGEDGE) begin : g_sync_rst_pos  // Sync reset, posedge clock

        always @(posedge clk_i)
            if      (!rst_n_i) q_o <= RST_VAL;
            else if ( sinit_i) q_o <= RST_VAL;
            else if ( en_i   ) q_o <= d_i;

    end else begin : g_sync_rst_neg                                // Sync reset, negedge clock

        always @(negedge clk_i)
            if      (!rst_n_i) q_o <= RST_VAL;
            else if ( sinit_i) q_o <= RST_VAL;
            else if ( en_i   ) q_o <= d_i;
    end
endgenerate

//=============================================================================
// PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if (WIDTH < 1) begin : CHECK_WIDTH
        initial $fatal(1, "arv_ipdff_sinit: WIDTH (%0d) must be >= 1.", WIDTH);
    end
endgenerate
// pragma translate_on

endmodule // arv_ipdff_sinit

`default_nettype wire
