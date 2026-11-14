//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    setup_commit
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : setup_commit.v
// Module Description : A write takes effect at the end of its ACCESS cycle, never at
//                      the end of SETUP: every REGOUT register and MDELEG are checked
//                      between the two edges.
//----------------------------------------------------------------------------
integer k;
reg [31:0] old, val;

initial begin
    start;
    for (k = 0; k < 8; k = k + 1) begin
        old = regout[k];
        val = ~old ^ (32'h0101_0101 << k);
        fork
            wr(MACHINE, 4*k, val);
            begin
                @(posedge free_clk); #2;                     // after the SETUP edge
                check_eq(regout[k], old, "register after SETUP");
                @(posedge free_clk); #2;                     // after the ACCESS edge
                check_eq(regout[k], val, "register after ACCESS");
            end
        join
    end
    // MDELEG: a new level applies from the next transfer on, back to back
    b2b = 1'b1;
    set_mdeleg(2'b00, 2'b00, 1'b1);
    wr_x(USER, 32'h4, 32'h0BAD_C0DE, 1'b0);
    set_mdeleg(2'b11, 2'b11, 1'b1);
    wr_x(USER, 32'h4, 32'hDEAD_BEEF, 1'b1);
    rd_x(MACHINE, 32'h4, 32'h0BAD_C0DE, 1'b0);
    finish;
end
