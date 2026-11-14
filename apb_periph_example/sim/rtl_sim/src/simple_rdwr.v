//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    simple_rdwr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : simple_rdwr.v
// Module Description : MDELEG reset value, then a word write and read back of every
//                      REGOUT register and a read of every REGIN input, in machine mode.
//----------------------------------------------------------------------------
integer k;

initial begin
    start;
    rd_x(MACHINE, MDELEG_ADDR, MDELEG_RST_WORD, 1'b0);
    for (k = 0; k < 8; k = k + 1) wr_x(MACHINE, 4*k, 32'hA5A5_0000 + k, 1'b0);
    for (k = 0; k < 8; k = k + 1) rd_x(MACHINE, 4*k, 32'hA5A5_0000 + k, 1'b0);
    idle(1);
    for (k = 0; k < 8; k = k + 1) regin[k] = 32'h5A5A_0000 + k;
    for (k = 0; k < 8; k = k + 1) rd_x(MACHINE, 32'h20 + 4*k, 32'h5A5A_0000 + k, 1'b0);
    if (xfers != 25) begin $display("ERROR: %0d transfers completed", xfers); error = error + 1; end
    finish;
end
