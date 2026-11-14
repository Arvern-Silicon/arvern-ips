//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    random_traffic
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : random_traffic.v
// Module Description : 2000 random transfers: modes, offsets across the whole window,
//                      reads and writes with random strobes and PPROT[2:1], MDELEG
//                      reprogramming (reserved encodings included), REGIN changes,
//                      back-to-back runs and idle gaps; the model predicts everything.
//----------------------------------------------------------------------------
integer n, k, sel;
reg [1:0] mode;

initial begin
    start;
    for (n = 0; n < 2000; n = n + 1) begin
        sel  = $random(seed) & 31;
        mode = $random(seed);
        if (mode == 2'b10) mode = MACHINE;
        k    = (sel < 24) ? ($random(seed) & 15) : (sel < 28) ? 16 : ($random(seed) & (WIN/4 - 1));
        b2b  = $random(seed) & 1;
        if (sel == 31) begin
            b2b = 1'b0;
            bus_idle;
            regin[$random(seed) & 7] = $random(seed);
            idle(1);
        end else if ((k == 16) && (sel & 1))
            xfer(1'b1, MACHINE, 4*k + ($random(seed) & 3), $random(seed), $random(seed), $random(seed), -1, 32'h0, 1'b0);
        else if ($random(seed) & 1)
            xfer(1'b1, mode, 4*k + ($random(seed) & 3), $random(seed), $random(seed), $random(seed), -1, 32'h0, 1'b0);
        else
            xfer(1'b0, mode, 4*k + ($random(seed) & 3), 32'h0, 4'h0, $random(seed), -1, 32'h0, 1'b0);
        if (!b2b && ($random(seed) & 1)) idle($random(seed) & 3);
    end
    finish;
end
