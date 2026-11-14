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
// Module Description : Offsets above MDELEG up to the top of the window: writes change
//                      nothing and reads return 0, with PSLVERR only for a mode below
//                      the MDELEG level; PADDR[1:0] does not select anything.
//----------------------------------------------------------------------------
integer w;

initial begin
    start;
    for (w = 17; w < WIN/4; w = w + 1) begin
        wr_x(MACHINE, 4*w, $random(seed), 1'b0);
        rd_x(MACHINE, 4*w, 32'h0, 1'b0);
        wr(USER,       4*w, $random(seed));                // PSLVERR per the reset MDELEG
        rd(SUPERVISOR, 4*w);
    end
    set_mdeleg(2'b00, 2'b00, 1'b1);
    for (w = 17; w < WIN/4; w = w + 1) begin
        wr_x(USER, 4*w, $random(seed), 1'b0);
        rd_x(USER, 4*w + 3, 32'h0, 1'b0);
    end
    // byte offsets inside a register word reach that register
    wrs(MACHINE, 32'h05, 32'h1122_3344, 4'b0010);
    rd(MACHINE, 32'h06);
    wr(MACHINE, 32'h1F, 32'hCAFE_F00D);
    rd(MACHINE, 32'h1C);
    finish;
end
