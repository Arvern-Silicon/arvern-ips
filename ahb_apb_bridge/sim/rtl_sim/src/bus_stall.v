//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    bus_stall
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bus_stall.v
// Module Description : Another subordinate's data phases stall the
//                      bus while the master holds address phases to the bridge
//                      (HREADY low with HSEL and NONSEQ): the bridge starts
//                      each transfer only once HREADY is high, so every AHB
//                      transfer gives exactly one APB transfer, with the right
//                      data.
//----------------------------------------------------------------------------
integer k, n, s0, nx;

initial begin
    @(posedge hresetn);
    repeat (2) @(posedge hclk);
    stall_pct = 85;
    s0 = apb_setups; nx = 0;
    // IDLE cycles between the transfers leave the bus to other data phases,
    // which stall it while the next address phase to the bridge is held
    for (n = 0; n < 80; n = n + 1) begin
        k = n % SLV_NR;
        set_wmax(n % 3);
        wr(win_base(k) + (4 * (n % 2)) % win_size(k), {16'h57A1, n[15:0]});
        push_kind(K_IDLE, 0);
        rd(win_base(k) + (4 * (n % 2)) % win_size(k));
        push_kind(K_IDLE, 0);
        push_kind(K_IDLE, 0);
        nx = nx + 2;
    end
    drain;
    stall_pct = 0;
    if (apb_setups - s0 != nx) begin
        $display("ERROR: %0d APB transfers for %0d AHB transfers", apb_setups - s0, nx); error = error + 1;
    end
    stimulus_done = 1'b1;
end
