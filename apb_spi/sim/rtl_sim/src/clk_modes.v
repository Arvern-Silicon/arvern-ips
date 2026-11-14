//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    clk_modes
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : clk_modes.v
// Module Description : Clock modes and bit / byte order: the four CPOL /
//                      CPHA pairs, each with MSB first, BSWAP, LSB_FIRST and
//                      both, on 8-, 16-, 24- and 32-bit transmit and receive
//                      frames in every lane width the build has; the monitor
//                      assembles every frame with the document's order rules.
//
// Doc "Frame format and clock modes".
//----------------------------------------------------------------------------

integer    m, o, n, l, lanes;
reg [31:0] ord;

initial
   begin
      wait_reset_done(5);
      cs_set(8'h00, 1, 1, 1);
      clk_set(1, 0);
      for (m = 0; m < 4; m = m + 1)
        for (o = 0; o < 4; o = o + 1)
          begin
             ord = ((o & 1) ? C_BSWAP : 0) | ((o & 2) ? C_LSB : 0);
             ctrl_wr(C_EN | C_IDLE_HIGH | (m[1] ? C_CPOL : 0) | (m[0] ? C_CPHA : 0) | ord);
             for (l = 0; l < 3; l = l + 1)
               begin
                  lanes = (l == 0) ? 1 : (l == 1) ? 2 : 4;
                  if (lanes <= LANES_MAX)
                    for (n = 8; n <= 32; n = n + 8)
                      begin
                         ent(xa(KTX, n, lanes, 1'b0, 1'b1, 1'b0, 0), $urandom);
                         if (RX_EN != 0) begin rq_push($urandom); ent(xa(KRX, n, lanes, 1'b0, 1'b1, 1'b0, 0), 0); end
                      end
               end
             ent_tx(8, 32'hFF, 1'b0);
             wait_idle(100000);
             rx_drain;
          end
      stimulus_done = 1;
   end
