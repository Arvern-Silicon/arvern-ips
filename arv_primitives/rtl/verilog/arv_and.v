//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_and
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_and.v
// Module Description : AND reduction as an explicit, PD-visible cell. Intended for
//                      RESET-NETWORK combining, where the gate must stay a single
//                      identifiable instance rather than be restructured, absorbed
//                      into downstream logic, or duplicated per fanout branch (which
//                      would skew reset arrival between flop groups).
//
//   PD note: keep the hierarchy through compile (no auto-ungroup), then set_size_only
//   on the mapped leaf -- match ref_name =~ arv_and* (elaboration appends the parameter).
//   Prefer size_only over dont_touch: the reset tree still needs sizing and buffering,
//   just not restructuring.
//----------------------------------------------------------------------------
`default_nettype none

module  arv_and #(
    parameter               N = 2             // number of inputs
) (
    input  wire [N-1:0]     a_i,
    output wire             z_o
);

assign z_o = &a_i;

//=============================================================================
// PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if (N < 1) begin : CHECK_N
        initial $fatal(1, "arv_and: N (%0d) must be >= 1.", N);
    end
endgenerate
// pragma translate_on

endmodule // arv_and

`default_nettype wire
