//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    slverr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : slverr.v
// Module Description : A completer's PSLVERR (the last word of a window
//                      wider than one word) ends the AHB transfer with the
//                      two-cycle ERROR response, for reads and writes, with and
//                      without wait states; the write is not posted (the next
//                      transfer only starts after the ERROR) and the traffic
//                      around it is unaffected.
//----------------------------------------------------------------------------
integer k, w;

initial begin
    @(posedge hresetn);
    repeat (2) @(posedge hclk);
    for (w = 0; w < 2; w = w + 1) begin
        set_wmax(w * 3);
        for (k = 0; k < SLV_NR; k = k + 1) begin
            wr(win_base(k), 32'h1234_0000 + k);
            wr(win_base(k) + win_size(k) - 4, 32'hFFFF_FFFF);
            rd(win_base(k) + win_size(k) - 4);
            rd(win_base(k));
        end
        drain;
    end
    stimulus_done = 1'b1;
end
