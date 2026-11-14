//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    rw_data_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : rw_data_walk.v
// Module Description : Walking ones and walking zeros through every REGOUT register,
//                      each value read back.
//----------------------------------------------------------------------------
integer k, b;

initial begin
    start;
    for (k = 0; k < 8; k = k + 1)
        for (b = 0; b < 32; b = b + 1) begin
            wr(MACHINE, 4*k,   32'h1 << b);  rd(MACHINE, 4*k);
            wr(MACHINE, 4*k, ~(32'h1 << b)); rd(MACHINE, 4*k);
        end
    finish;
end
