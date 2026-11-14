//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    priv_levels
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : priv_levels.v
// Module Description : Every WR_PRIV / RD_PRIV level (reserved included), both RESP
//                      values, every requester mode: write and read of a REGOUT and a
//                      REGIN register, PSLVERR stated independently of the model.
//----------------------------------------------------------------------------
integer wp, rp, rs, m, k;
reg [1:0] mode, cw, cr;
reg       ew, er;

initial begin
    for (k = 0; k < 8; k = k + 1) regin[k] = $random(seed) | 32'h1;
    start;
    for (wp = 0; wp < 4; wp = wp + 1)
      for (rp = 0; rp < 4; rp = rp + 1)
        for (rs = 0; rs < 2; rs = rs + 1) begin
            set_mdeleg(wp[1:0], rp[1:0], rs[0]);
            cw = (wp == 2) ? 2'b11 : wp[1:0];
            cr = (rp == 2) ? 2'b11 : rp[1:0];
            for (m = 0; m < 3; m = m + 1) begin
                mode = (m == 0) ? USER : (m == 1) ? SUPERVISOR : MACHINE;
                ew   = rs[0] & (mode < cw);
                er   = rs[0] & (mode < cr);
                k    = $random(seed) & 7;
                xfer(1'b1, mode, 4*k,          $random(seed), 4'hF, 2'b00, ew, 32'h0, 1'b0);
                xfer(1'b0, mode, 4*k,          32'h0,         4'h0, 2'b00, er, 32'h0, 1'b0);
                xfer(1'b1, mode, 32'h20 + 4*k, $random(seed), 4'hF, 2'b00, ew, 32'h0, 1'b0);
                xfer(1'b0, mode, 32'h20 + 4*k, 32'h0,         4'h0, 2'b00, er, 32'h0, 1'b0);
            end
        end
    finish;
end
