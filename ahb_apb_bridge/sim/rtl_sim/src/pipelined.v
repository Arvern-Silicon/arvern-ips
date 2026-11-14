//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    pipelined
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : pipelined.v
// Module Description : Back-to-back reads and writes alternating
//                      between completers, the next address phase in the cycle
//                      the previous transfer completes, with and without wait
//                      states and with ERRORs among them.
//----------------------------------------------------------------------------
integer k, n, w;

initial begin
    @(posedge hresetn);
    repeat (2) @(posedge hclk);
    for (w = 0; w < 3; w = w + 1) begin
        set_wmax(w * 2);
        for (n = 0; n < 24; n = n + 1) begin
            k = (n * 7) % SLV_NR;
            case (n % 4)
                0: wr(win_base(k) + (4 * (n % 2)) % win_size(k), {8'hC0, n[7:0], w[7:0], k[7:0]});
                1: rd(win_base(k) + (4 * ((n + 1) % 2)) % win_size(k));
                2: rd(win_base(k) + win_size(k) - 4);                  // PSLVERR, except in a one-word window
                3: push_xfer(1'b1, win_base(k) + 1, 3'd0, 32'h0000_7700);
            endcase
        end
        drain;
    end
    stimulus_done = 1'b1;
end
