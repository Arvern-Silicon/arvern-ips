//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    aclint_gray2bin
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : aclint_gray2bin.v
// Module Description : Combinational Gray-to-binary converter. Each binary
//                      output bit is the XOR-reduction of all gray bits at
//                      or above that position:
//                          binary[i] = XOR( gray[W-1] ... gray[i] )
//                      Purely combinational. Used by the MTIMER read-CDC to
//                      convert a captured Gray-encoded counter snapshot back
//                      to binary on the AHB side.
//
// IMPLEMENTATION NOTE: The per-bit XOR-reduction form above is logically
//                      identical to the textbook recursive form
//                          binary[i] = binary[i+1] ^ gray_i[i]
//                      but expresses each output as a direct function of a
//                      distinct input slice. This avoids Verilator's
//                      UNOPTFLAT false-positive on the recursive binary ->
//                      binary dataflow without changing synthesis cost or
//                      timing (the synthesizer collapses both forms to the
//                      same XOR tree).
//----------------------------------------------------------------------------
`default_nettype none

module  aclint_gray2bin #(
    parameter           W = 64               // Bus width (>=1)
) (
    input  wire [W-1:0] gray_i,              // Gray-encoded input
    output wire [W-1:0] binary_o             // Binary-decoded output
);


//=============================================================================
// 1)  GRAY-TO-BINARY CONVERSION
//=============================================================================
// See module header for the XOR-reduction-vs-recursive-form rationale.

wire [W-1:0] binary;

genvar gi;
generate
    for (gi = 0; gi < W; gi = gi + 1) begin : G_GRAY2BIN
        assign binary[gi] = ^gray_i[W-1:gi];
    end
endgenerate

assign binary_o = binary;


//=============================================================================
// 2)  PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if (W < 1) begin : CHECK_W
        initial $fatal(1, "aclint_gray2bin: W (%0d) must be >= 1.", W);
    end
endgenerate
// pragma translate_on

endmodule // aclint_gray2bin

`default_nettype wire
