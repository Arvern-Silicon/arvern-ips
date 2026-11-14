//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    oversize
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : oversize.v
// Module Description : HSIZE wider than a word (3 to 7) gets the
//                      two-cycle ERROR with no APB transfer, at a decoded
//                      address of every completer.
//----------------------------------------------------------------------------
integer k, z, s0;

initial begin
    @(posedge hresetn);
    repeat (2) @(posedge hclk);
    s0 = apb_setups;
    for (k = 0; k < SLV_NR; k = k + 1)
        for (z = 3; z < 8; z = z + 1) begin
            push_xfer(1'b0, win_base(k), z, 32'h0);
            push_xfer(1'b1, win_base(k), z, 32'hFFFF_FFFF);
        end
    for (k = 0; k < SLV_NR; k = k + 1) rd(win_base(k));
    drain;
    if (apb_setups - s0 != SLV_NR) begin $display("ERROR: %0d APB transfers, expected %0d", apb_setups - s0, SLV_NR); error = error + 1; end
    stimulus_done = 1'b1;
end
