//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    aclint_mtimer_gray_sync
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : aclint_mtimer_gray_sync.v
// Module Description : Per-bit 2-FF synchronizer for the 64-bit Gray-encoded
//                      MTIME bus, plus a Gray-to-binary converter and a
//                      2-cycle warmup pipeline.
//
// CONTRACT           : read_req_i must be issued at least 2 hclk_i cycles
//                      after hclk_i has been ungated, so the 2-FF gray sync
//                      chain has had time to flush stale values from the
//                      pre-gate state. The parent (aclint_mtimer) enforces
//                      this naturally: the read FSM only emits read_req in
//                      IDLE, and IDLE is only re-entered after a previous
//                      mtime_valid -- which itself required 2 hclk edges to
//                      propagate. Any future caller bypassing the FSM must
//                      honour this invariant.
//----------------------------------------------------------------------------
`default_nettype none

module  aclint_mtimer_gray_sync #(
    parameter          ARST_EN = 1'b1           // Reset style: 1=asynchronous, 0=synchronous
) (

// CLOCK & RESET (hclk DOMAIN ONLY)
    input  wire        hclk_i,                  // AHB clock domain
    input  wire        hresetn_i,               // Active-low async reset (hclk)

// LIVE GRAY COUNTER (LF DOMAIN)
    input  wire [63:0] mtime_gray_lf_i,         // LF-domain Gray-encoded MTIME

// REQUEST / RESPONSE (hclk DOMAIN)
    input  wire        read_req_i,              // 1-cycle pulse: start a read
    output wire [63:0] mtime_binary_o,          // Latched 64-bit binary snapshot
    output wire        mtime_valid_o            // 1-cycle pulse: new value latched
);


//=============================================================================
// 1)  PER-BIT 2-FF SYNCHRONIZER ON THE 64-BIT GRAY BUS
//=============================================================================
// Two stages of hclk-clocked flops on every Gray bit. Resolves any single-bit
// metastable sample to a stable old-or-new value within 2 hclk cycles.

wire [63:0] mtime_gray_sync;

arv_synchronizer #(
    .W                 ( 64                ),
    .ARST_EN           ( ARST_EN           )
) u_gray_sync (
    .clk_i             ( hclk_i            ),
    .resetn_i          ( hresetn_i         ),
    .async_i           ( mtime_gray_lf_i   ),
    .sync_o            ( mtime_gray_sync   )
);


//=============================================================================
// 2)  GRAY-TO-BINARY CONVERSION (COMBINATIONAL OUTPUT)
//=============================================================================
// Live binary view of the synchronized Gray bus. Updates every hclk cycle.
// Driven combinationally to mtime_binary_o; the parent's mtime_shadow flop
// latches it on mtime_valid_o.

aclint_gray2bin #(.W(64)) u_gray2bin (
    .gray_i   ( mtime_gray_sync ),
    .binary_o ( mtime_binary_o  )
);


//=============================================================================
// 3)  2-CYCLE WARMUP PIPELINE
//=============================================================================
// read_req_i shifts through a 2-stage pipeline. mtime_valid_o pulses on the
// 2nd stage, by which point the synchronizer has had 2 fresh hclk edges
// between read_req_i and the sample -- safe even if hclk was gated and
// resumed at the read_req_i cycle.

wire pend_1;
wire pend_2;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_pend_1 (
               .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(read_req_i), .q_o(pend_1));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_pend_2 (
               .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(pend_1),    .q_o(pend_2));

assign mtime_valid_o  = pend_2;

endmodule // aclint_mtimer_gray_sync

`default_nettype wire
