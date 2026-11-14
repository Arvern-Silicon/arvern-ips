//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    data_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : data_walk.v
// Module Description : Walking ones and walking zeros written to and
//                      read back from every completer, so every bit of PWDATA
//                      and of each completer's PRDATA carries both values
//                      through the bridge.
//----------------------------------------------------------------------------
integer k, b;

initial begin
    @(posedge hresetn);
    repeat (2) @(posedge hclk);
    for (k = 0; k < SLV_NR; k = k + 1)
        for (b = 0; b < 32; b = b + 1) begin
            wr(win_base(k) + (4 % win_size(k)), 32'h1 << b);
            rd(win_base(k) + (4 % win_size(k)));
            wr(win_base(k) + (4 % win_size(k)), ~(32'h1 << b));
            rd(win_base(k) + (4 % win_size(k)));
        end
    drain;
    stimulus_done = 1'b1;
end
