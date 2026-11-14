//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mdeleg_lanes
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mdeleg_lanes.v
// Module Description : MDELEG byte lanes: PSTRB[0] writes WR_PRIV and RD_PRIV, PSTRB[1]
//                      writes RESP, PSTRB[3:2] nothing; the reserved privilege
//                      encoding 2 is stored as 3.
//----------------------------------------------------------------------------
initial begin
    start;
    set_mdeleg(2'b11, 2'b11, 1'b1);                         // known start, whatever MDELEG_RST is
    wrs(MACHINE, MDELEG_ADDR, 32'h0000_0004, 4'b0001);     // RD_PRIV=1, WR_PRIV=0
    rd_x(MACHINE, MDELEG_ADDR, 32'h0000_0104, 1'b0);
    wrs(MACHINE, MDELEG_ADDR, 32'h0000_000F, 4'b0010);     // RESP=0 only
    rd_x(MACHINE, MDELEG_ADDR, 32'h0000_0004, 1'b0);
    wrs(MACHINE, MDELEG_ADDR, 32'hFFFF_FFFF, 4'b1100);     // no lane of MDELEG
    rd_x(MACHINE, MDELEG_ADDR, 32'h0000_0004, 1'b0);
    wrs(MACHINE, MDELEG_ADDR, 32'hFFFF_FFFF, 4'b0000);     // no strobe
    rd_x(MACHINE, MDELEG_ADDR, 32'h0000_0004, 1'b0);
    wrs(MACHINE, MDELEG_ADDR, 32'h0000_010A, 4'b0011);     // both fields reserved
    rd_x(MACHINE, MDELEG_ADDR, 32'h0000_010F, 1'b0);
    wrs(MACHINE, MDELEG_ADDR, 32'h0000_0109, 4'b0011);     // WR_PRIV=1, RD_PRIV reserved
    rd_x(MACHINE, MDELEG_ADDR, 32'h0000_010D, 1'b0);
    wrs(MACHINE, MDELEG_ADDR, 32'h0000_0106, 4'b0011);     // WR_PRIV reserved, RD_PRIV=1
    rd_x(MACHINE, MDELEG_ADDR, 32'h0000_0107, 1'b0);
    wrs(MACHINE, MDELEG_ADDR, 32'hFFFF_FEF0, 4'b1111);     // reserved bits read 0
    rd_x(MACHINE, MDELEG_ADDR, 32'h0000_0000, 1'b0);
    finish;
end
