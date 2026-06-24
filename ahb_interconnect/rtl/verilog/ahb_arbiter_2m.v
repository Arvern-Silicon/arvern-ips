//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_arbiter_2m
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_arbiter_2m.v
// Module Description : 2-manager AHB arbiter (round-robin / toggle priority).
//
// CORRECTNESS GUARANTEE: grant_o is one-hot in every cycle (at most one bit
// high). Downstream `ahb_manager_mux` data-phase OR-combine relies on this.
//----------------------------------------------------------------------------
`default_nettype none

module  ahb_arbiter_2m #(
    parameter         ARST_EN = 1'b1     // 1=async active-low reset, 0=synchronous reset
) (

// AHB CLOCK & RESET
    input  wire       hclk_i,
    input  wire       hresetn_i,

// ARBITER INTERFACES
    input  wire [1:0] request_i,
    output wire [1:0] grant_o
);


//=============================================================================
// 1)  ARBITER
//=============================================================================

// Toggle Flop
wire toggle_priority;

// grant_o is one-hot, so grant_o[0] takes priority and selects the next value:
//   grant_o[0] -> 1 ; grant_o[1] -> 0 ; (hold otherwise)
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_toggle_priority (
                        .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(grant_o[0] | grant_o[1]),
                                                             .d_i (grant_o[0]),
                                                             .q_o (toggle_priority));

// Grant request
assign grant_o = toggle_priority ? {                request_i[1], request_i[0] & ~request_i[1]} : // Toggled priority: 1. M1 / 2. M0
                                   {~request_i[0] & request_i[1], request_i[0]                } ; // Default priority: 1. M0 / 2. M1

endmodule

`default_nettype wire
