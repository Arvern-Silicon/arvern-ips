//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    busy_idle
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : busy_idle.v
// Module Description : IDLE and BUSY address phases (selected, at
//                      decoded addresses) between transfers start no APB
//                      transfer and change nothing.
//----------------------------------------------------------------------------
integer k, s0;

initial begin
    @(posedge hresetn);
    repeat (2) @(posedge hclk);
    s0 = apb_setups;
    for (k = 0; k < SLV_NR; k = k + 1) begin
        wr(win_base(k), 32'h0BEE_0000 + k);
        push_kind(K_IDLE, win_base(k));
        push_kind(K_BUSY, win_base(k));
        push_kind(K_BUSY, win_base(k) + 4);
        rd(win_base(k));
        push_kind(K_IDLE, win_base(k));
        push_kind(K_IDLE, win_base(k));
    end
    drain;
    if (apb_setups - s0 != 2 * SLV_NR) begin $display("ERROR: %0d APB transfers, expected %0d", apb_setups - s0, 2 * SLV_NR); error = error + 1; end
    stimulus_done = 1'b1;
end
