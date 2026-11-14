//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    wait_states
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : wait_states.v
// Module Description : Completers inserting 0 to 5 wait states at
//                      random; every transfer's data and response stay right,
//                      and the AHB wait states are the APB ones plus two
//                      (checked per transfer by the master; here their range).
//----------------------------------------------------------------------------
integer k, n, nw;

initial begin
    @(posedge hresetn);
    repeat (2) @(posedge hclk);
    set_wmax(5);
    for (n = 0; n < 40; n = n + 1)
        for (k = 0; k < SLV_NR; k = k + 1) begin
            nw = (win_size(k) > 4) ? win_size(k) / 4 - 1 : 1;     // the words without PSLVERR
            wr(win_base(k) + 4 * (n % nw), {n[15:0], k[15:0]});
            rd(win_base(k) + 4 * (n % nw));
        end
    drain;
    $display("wait_states: %0d transfers, AHB wait states %0d-%0d", ahb_xfers, min_wait, max_wait);
    if ((min_wait != 2) || (max_wait < 5) || (max_wait > 7)) begin
        $display("ERROR: AHB wait states %0d-%0d, expected 2 to 7", min_wait, max_wait); error = error + 1;
    end
    stimulus_done = 1'b1;
end
