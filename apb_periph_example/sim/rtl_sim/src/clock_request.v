//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    clock_request
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : clock_request.v
// Module Description : pclk_en_o follows PSEL: low while no transfer runs, high in
//                      SETUP and ACCESS. It has no reset term (the reset generator
//                      requests the clock), so it is low in reset while PSEL is.
//----------------------------------------------------------------------------
integer n;

initial begin
    start;
    idle(1);
    repeat (4) begin @(negedge free_clk); check_eq(pclk_en, 1'b0, "pclk_en_o idle"); end
    @(posedge free_clk); #1;
    fork
        wr(MACHINE, 32'h8, 32'h55AA_55AA);
        begin
            @(negedge free_clk); check_eq(pclk_en, 1'b1, "pclk_en_o in SETUP");
            @(negedge free_clk); check_eq(pclk_en, 1'b1, "pclk_en_o in ACCESS");
        end
    join
    @(negedge free_clk); check_eq(pclk_en, 1'b0, "pclk_en_o after the transfer");
    #2 presetn = 1'b0;
    @(negedge free_clk); check_eq(pclk_en, 1'b0, "pclk_en_o in reset");
    repeat (2) @(posedge free_clk);
    #3 presetn = 1'b1;
    check_eq(regout[2], 32'h0, "register after reset");
    @(posedge free_clk); #1;
    for (n = 0; n < 4; n = n + 1) begin
        wr(MACHINE, 4*n, 32'hC0DE_0000 + n);
        idle(n);
        rd(MACHINE, 4*n);
    end
    finish;
end
