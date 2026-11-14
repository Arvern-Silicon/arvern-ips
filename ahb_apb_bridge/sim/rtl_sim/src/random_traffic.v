//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    random_traffic
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : random_traffic.v
// Module Description : 2000 random transfers (any completer or
//                      gap, any size including illegal ones, misaligned ones
//                      among them, reads and writes,
//                      IDLE/BUSY/unselected phases in between) with random wait
//                      states, checked against the reference memory.
//----------------------------------------------------------------------------
integer n, r, k, s;
reg [ADDRW-1:0] a;
integer seed;

initial begin
    seed = `SEED;
    @(posedge hresetn);
    repeat (2) @(posedge hclk);
    set_wmax(4);
    for (n = 0; n < 2000; n = n + 1) begin
        r = {$random(seed)} % 100;
        k = {$random(seed)} % SLV_NR;
        a = ((r < 8) ? $random(seed) : (win_base(k) + ({$random(seed)} % win_size(k))));
        s = ({$random(seed)} % 100 < 4) ? 3 + {$random(seed)} % 5 : {$random(seed)} % 3;
        if ({$random(seed)} % 100 < 95) begin          // 5 % keep a misaligned address
            if (s == 1) a[0] = 1'b0;
            if (s == 2) a[1:0] = 2'b00;
        end
        cur_prot  = {$random(seed)} % 16;
        cur_smode = $random(seed);
        cur_master = {$random(seed)} % 16;
        if (r < 4)       push_kind(K_IDLE, a);
        else if (r < 6)  push_kind(K_BUSY, a);
        else if (r < 8)  push_kind(K_NOSEL, a);
        else if (r < 54) push_xfer(1'b1, a, s, $random(seed));
        else             push_xfer(1'b0, a, s, 32'h0);
        if ((n % 500) == 499) drain;
    end
    drain;
    $display("random_traffic: %0d transfers", ahb_xfers);
    stimulus_done = 1'b1;
end
