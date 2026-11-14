//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    strobes
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : strobes.v
// Module Description : Every PSTRB pattern, zero included, on every REGOUT register:
//                      only the strobed byte lanes change.
//----------------------------------------------------------------------------
integer k, s;

initial begin
    start;
    for (k = 0; k < 8; k = k + 1) begin
        wr(MACHINE, 4*k, 32'h0);
        for (s = 0; s < 16; s = s + 1) begin
            wrs(MACHINE, 4*k, $random(seed), s[3:0]);
            rd(MACHINE, 4*k);
        end
    end
    finish;
end
