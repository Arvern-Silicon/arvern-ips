//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mdeleg_reset
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mdeleg_reset.v
// Module Description : MDELEG comes out of reset at MDELEG_RST, and the gates it
//                      holds apply from the first transfer: every mode reads and
//                      writes a REGOUT and a REGIN register before any MDELEG
//                      write. MDELEG is then rewritten, and a reset restores it.
//----------------------------------------------------------------------------
integer k, m;
reg [1:0] mode;

task sweep;
    begin
        rd_x(MACHINE, MDELEG_ADDR, MDELEG_RST_WORD, 1'b0);
        for (m = 0; m < 3; m = m + 1) begin
            mode = (m == 0) ? USER : (m == 1) ? SUPERVISOR : MACHINE;
            wr(mode, 32'h4 * m, 32'hC0DE_0000 + m);
            rd(mode, 32'h4 * m);
            rd(mode, 32'h20 + 32'h4 * m);
            wr(mode, 32'h20 + 32'h4 * m, 32'hFFFF_FFFF);          // REGIN is read-only
        end
    end
endtask

initial begin
    start;
    for (k = 0; k < 8; k = k + 1) regin[k] = 32'h1111_1111 * (k + 1);
    sweep;
    // Rewrite MDELEG to a value different from the reset one in every field
    set_mdeleg((MDELEG_RST[1:0] == 2'b11) ? 2'b00 : 2'b11,
               (MDELEG_RST[3:2] == 2'b11) ? 2'b00 : 2'b11,
               ~MDELEG_RST[8]);
    rd(MACHINE, MDELEG_ADDR);
    // Reset between transfers
    #3 presetn = 1'b0;
    repeat (3) @(posedge free_clk);
    #3 presetn = 1'b1;
    @(posedge free_clk); #1;
    sweep;
    finish;
end
