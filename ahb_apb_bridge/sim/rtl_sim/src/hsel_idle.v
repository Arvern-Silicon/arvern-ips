//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    hsel_idle
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : hsel_idle.v
// Module Description : NONSEQ address phases with HSEL low (another
//                      subordinate's transfers) start nothing and leave
//                      HREADYOUT high; the bridge then serves its own transfers
//                      normally.
//----------------------------------------------------------------------------
integer k, s0, low;

initial begin
    @(posedge hresetn);
    repeat (2) @(posedge hclk);
    s0 = apb_setups; low = 0;
    for (k = 0; k < SLV_NR; k = k + 1) begin
        push_kind(K_NOSEL, win_base(k));
        push_kind(K_NOSEL, win_base(k) + (4 % win_size(k)));
        wr(win_base(k) + (4 % win_size(k)), 32'h5E1_0000 + k);
        push_kind(K_NOSEL, win_base(k));
        rd(win_base(k) + (4 % win_size(k)));
    end
    drain;
    if (apb_setups - s0 != 2 * SLV_NR) begin $display("ERROR: %0d APB transfers, expected %0d", apb_setups - s0, 2 * SLV_NR); error = error + 1; end
    stimulus_done = 1'b1;
end
