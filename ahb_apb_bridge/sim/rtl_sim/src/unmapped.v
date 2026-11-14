//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    unmapped
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : unmapped.v
// Module Description : An address inside the bridge window that no
//                      completer decodes gets the two-cycle ERROR with no APB
//                      transfer: a sweep of the window and the words right
//                      after and right before every completer's window; the map
//                      without gaps (one completer) has none, so the test only
//                      counts there.
//----------------------------------------------------------------------------
integer a, n, s0, k;

initial begin
    @(posedge hresetn);
    repeat (2) @(posedge hclk);
    n  = 0;
    s0 = apb_setups;
    for (a = 0; a < (1 << ADDRW); a = a + ((1 << ADDRW) / 64))
        if (slv_of(a) < 0) begin
            rd(a); wr(a, 32'hBAD0_0000 + a); n = n + 1;
        end
    for (k = 0; k < SLV_NR; k = k + 1) begin
        a = win_base(k) + win_size(k);
        if ((a < (1 << ADDRW)) && (slv_of(a) < 0)) begin rd(a); wr(a, 32'h0); n = n + 1; end
        a = win_base(k) - 4;
        if ((a >= 0) && (slv_of(a) < 0)) begin rd(a); wr(a, 32'h0); n = n + 1; end
    end
    rd(0);
    drain;
    $display("unmapped: %0d unmapped addresses tried", n);
    if (apb_setups - s0 != ((slv_of(0) >= 0) ? 1 : 0)) begin
        $display("ERROR: %0d APB transfers for unmapped addresses", apb_setups - s0 - 1); error = error + 1;
    end
    if ((CFG == 0) && (n == 0)) begin $display("ERROR: no unmapped address in the gapped map"); error = error + 1; end
    stimulus_done = 1'b1;
end
