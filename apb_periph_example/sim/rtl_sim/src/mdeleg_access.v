//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mdeleg_access
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mdeleg_access.v
// Module Description : MDELEG is machine-mode only: supervisor and user accesses get
//                      PSLVERR with RESP=1 and are ignored with RESP=0 (reads return 0),
//                      even with the registers delegated to user mode.
//----------------------------------------------------------------------------
integer m;
reg [1:0] mode;

initial begin
    start;
    for (m = 0; m < 2; m = m + 1) begin
        mode = (m == 0) ? USER : SUPERVISOR;
        wr(mode, MDELEG_ADDR, 32'h0000_0000);               // refused; PSLVERR per the reset RESP
        rd(mode, MDELEG_ADDR);
    end
    rd_x(MACHINE, MDELEG_ADDR, MDELEG_RST_WORD, 1'b0);
    set_mdeleg(2'b00, 2'b00, 1'b1);                         // registers open to user mode
    for (m = 0; m < 2; m = m + 1) begin
        mode = (m == 0) ? USER : SUPERVISOR;
        wr_x(mode, MDELEG_ADDR, 32'h0000_000F, 1'b1);
        rd_x(mode, MDELEG_ADDR, 32'h0, 1'b1);
    end
    set_mdeleg(2'b00, 2'b00, 1'b0);
    for (m = 0; m < 2; m = m + 1) begin
        mode = (m == 0) ? USER : SUPERVISOR;
        wr_x(mode, MDELEG_ADDR, 32'h0000_010F, 1'b0);
        rd_x(mode, MDELEG_ADDR, 32'h0, 1'b0);
    end
    rd_x(MACHINE, MDELEG_ADDR, 32'h0000_0000, 1'b0);
    finish;
end
