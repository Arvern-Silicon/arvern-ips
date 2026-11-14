//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    loopback
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : loopback.v
// Module Description : Loopback: single-lane transmit frames with CAPT read
//                      back their own payload through LOOPBACK, on the IO1
//                      and on the IO0 receive lane; a receive frame reads
//                      the IO0 idle level.
//
// Doc "Transmit, receive and status" (loopback).
//----------------------------------------------------------------------------

integer    i, r;
reg [31:0] d;

initial
   begin
      wait_reset_done(5);
      if (RX_EN == 0) tb_skip("needs the receive path");
      cs_set(8'h00, 1, 1, 1);
      clk_set(1, 0);
      for (r = 0; r < 2; r = r + 1)
        begin
           ctrl_wr(C_EN | C_IDLE_HIGH | C_LOOPBACK | (r ? C_RX_IO0 : 0));
           for (i = 0; i < 6; i = i + 1)
             begin
                d = $urandom;
                ent_txc(32, d, 1'b1);
             end
           ent_rx(8, 1, 1'b0);
           wait_idle(100000);
           rx_drain;
           for (i = 0; i < 7; i = i + 1)
             chk32(rx_got[x_rd - 7 + i], x_rx[x_rd - 7 + i], "loopback word");
           chk32(rx_got[x_rd - 1], 32'hFF, "receive frame reads the IO0 idle level");
        end
      ctrl_wr(C_EN | C_IDLE_HIGH);
      rq_push(32'h3C);
      ent_rx(8, 1, 1'b0);
      wait_idle(100000);
      rx_drain;
      stimulus_done = 1;
   end
