//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_cgate
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_cgate.v
// Module Description : Integrated clock gate. The enable is captured by a latch
//                      that is transparent while clk_i is LOW, so the gate can
//                      only ever change while the clock is low -- the output is
//                      glitch-free by construction, whatever the enable does.
//
//   test_en_i forces the clock on for scan shift; leave it low in functional use
//   and tie it to the DFT scan-enable on ASIC (a gate without it blocks the chain).
//
//   PD note: this is the standard latch+AND ICG structure, so a technology ICG
//   maps onto it directly -- swap in the library cell here if the flow prefers an
//   explicit instance. The latch is INTENTIONAL (lint-waived): do not "fix" it,
//   and do not let synthesis decompose it into random logic.
//----------------------------------------------------------------------------
`default_nettype none

module  arv_cgate (
    input  wire              clk_i,            // free-running clock in
    input  wire              en_i,             // functional enable
    input  wire              test_en_i,        // scan/test enable (forces the clock on)
    output wire              clk_o             // gated clock out
);

reg en_lat;

always @(*)
    if (~clk_i) en_lat = en_i | test_en_i;     // transparent-low latch (intentional)

assign clk_o = clk_i & en_lat;

endmodule // arv_cgate

`default_nettype wire
