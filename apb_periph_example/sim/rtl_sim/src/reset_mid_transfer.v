//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    reset_mid_transfer
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : reset_mid_transfer.v
// Module Description : A reset during the ACCESS of a write and during the SETUP of a
//                      write: the write is lost, every register and MDELEG return to
//                      their reset values, and transfers resume afterwards.
//----------------------------------------------------------------------------
integer k, ph;

initial begin
    start;
    for (ph = 0; ph < 2; ph = ph + 1) begin
        for (k = 0; k < 8; k = k + 1) wr(MACHINE, 4*k, $random(seed));
        set_mdeleg(2'b00, 2'b01, 1'b0);
        fork
            wr(MACHINE, 32'h0, 32'hFFFF_FFFF);
            begin
                if (ph == 0) @(posedge free_clk);            // into ACCESS
                #3 presetn = 1'b0;
                repeat (3) @(posedge free_clk);
                #3 presetn = 1'b1;
            end
        join
        idle(1);
        for (k = 0; k < 8; k = k + 1) check_eq(regout[k], 32'h0, "register after reset");
        rd_x(MACHINE, MDELEG_ADDR, MDELEG_RST_WORD, 1'b0);
        wr(USER, 32'h0, 32'h1);                             // outcome per the reset value
        wr_x(MACHINE, 32'h0, 32'h1, 1'b0);
        rd_x(MACHINE, 32'h0, 32'h1, 1'b0);
    end
    finish;
end
