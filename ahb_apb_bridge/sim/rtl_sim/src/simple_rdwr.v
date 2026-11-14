//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    simple_rdwr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : simple_rdwr.v
// Module Description : A word write then read back at the base and
//                      near the top of every completer's window, no wait
//                      states.
//----------------------------------------------------------------------------
integer k;

initial begin
    @(posedge hresetn);
    repeat (2) @(posedge hclk);
    for (k = 0; k < SLV_NR; k = k + 1) begin
        wr(win_base(k),                    32'hA5A5_0000 + k);
        wr(win_base(k) + win_size(k) - 8,  32'h5A5A_0000 + k);
        rd(win_base(k));
        rd(win_base(k) + win_size(k) - 8);
    end
    drain;
    $display("simple_rdwr: %0d transfers, %0d-%0d wait states", ahb_xfers, min_wait, max_wait);
    if (ahb_xfers != 4 * SLV_NR) begin $display("ERROR: %0d transfers completed", ahb_xfers); error = error + 1; end
    stimulus_done = 1'b1;
end
