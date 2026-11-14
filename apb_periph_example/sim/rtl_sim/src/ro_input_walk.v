//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ro_input_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ro_input_walk.v
// Module Description : Walking ones and zeros on every REGIN input, read back; writes
//                      to the REGIN offsets change nothing.
//----------------------------------------------------------------------------
integer k, b;

initial begin
    start;
    for (k = 0; k < 8; k = k + 1) begin
        for (b = 0; b < 32; b = b + 1) begin
            regin[k] =   32'h1 << b;  rd(MACHINE, 32'h20 + 4*k);
            regin[k] = ~(32'h1 << b); rd(MACHINE, 32'h20 + 4*k);
        end
        wr(MACHINE, 32'h20 + 4*k, $random(seed));
        rd_x(MACHINE, 32'h20 + 4*k, regin[k], 1'b0);
    end
    finish;
end
