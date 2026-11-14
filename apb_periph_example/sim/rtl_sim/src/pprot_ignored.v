//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    pprot_ignored
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : pprot_ignored.v
// Module Description : PPROT[2] (instruction) and PPROT[1] (non-secure) change nothing:
//                      every combination against every mode and MDELEG level gives the
//                      model's outcome.
//----------------------------------------------------------------------------
integer x, m, k, lvl;
reg [1:0] mode;

initial begin
    start;
    for (lvl = 0; lvl < 3; lvl = lvl + 1) begin
        set_mdeleg(lvl[1:0], lvl[1:0], 1'b1);
        for (x = 0; x < 4; x = x + 1)
            for (m = 0; m < 3; m = m + 1) begin
                mode = (m == 0) ? USER : (m == 1) ? SUPERVISOR : MACHINE;
                k    = $random(seed) & 7;
                xfer(1'b1, mode, 4*k,        $random(seed), 4'hF, x[1:0], -1, 32'h0, 1'b0);
                xfer(1'b0, mode, 4*k,        32'h0,         4'h0, x[1:0], -1, 32'h0, 1'b0);
                xfer(1'b0, mode, MDELEG_ADDR, 32'h0,        4'h0, x[1:0], -1, 32'h0, 1'b0);
            end
    end
    finish;
end
