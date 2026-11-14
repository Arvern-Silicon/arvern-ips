//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    back_to_back
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : back_to_back.v
// Module Description : Transfers with no idle cycle between them (SETUP right after
//                      ACCESS): a write then a read of the same register, MDELEG
//                      changes taking effect on the next transfer, then 300 random
//                      transfers in one stream.
//----------------------------------------------------------------------------
integer n, k;
reg [1:0] mode;

initial begin
    start;
    b2b = 1'b1;
    for (k = 0; k < 8; k = k + 1) begin
        wr(MACHINE, 4*k, $random(seed));
        rd(MACHINE, 4*k);
    end
    set_mdeleg(2'b00, 2'b00, 1'b1);
    wr_x(USER, 32'h0, 32'h1234_5678, 1'b0);                 // allowed from the next transfer on
    set_mdeleg(2'b11, 2'b11, 1'b1);
    wr_x(USER, 32'h0, 32'h8765_4321, 1'b1);
    rd_x(MACHINE, 32'h0, 32'h1234_5678, 1'b0);
    for (n = 0; n < 300; n = n + 1) begin
        mode = $random(seed);
        if (mode == 2'b10) mode = MACHINE;
        k    = $random(seed) % 20;
        if (k < 0) k = -k;
        if (k == 17) set_mdeleg($random(seed), $random(seed), $random(seed));
        else if ($random(seed) & 1) wrs(mode, 4*k, $random(seed), $random(seed));
        else                        rd(mode, 4*k);
    end
    finish;
end
