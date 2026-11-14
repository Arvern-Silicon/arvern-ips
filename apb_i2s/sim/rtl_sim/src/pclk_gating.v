//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    pclk_gating
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : pclk_gating.v
// Module Description : Clock request: the bus clock (gated by pclk_en_o
//                      alone in this bench) runs during transfers, one edge
//                      after them, while EN is set and until the engine has
//                      stopped; the receive FIFO is drained and the transmit
//                      FIFO filled, flushed and refilled with EN = 0 and idle
//                      gaps between transfers, every word checked.
//
// Doc "Clocks and sample rate" (pclk_en_o). The bench's always-on check
// compares pclk_en_o with PSEL | EN | running | a transfer on the last edge.
//----------------------------------------------------------------------------

integer i, txl, rxl, n;
reg [31:0] v;

initial
   begin
      wait_reset_done(5);
      repeat (20) @(posedge free_clk);
      chk(pclk_en === 1'b0, "pclk_en_o low while idle");
      if (RX_EN != 0)
        begin
           n = (RX_DEPTH < 6) ? RX_DEPTH : 6;
           i2s_setup(1, 3'd0, F_I2S, 1'b0);
           i2s_start(C_RX_ON);
           rx_wait_level(n);
           i2s_stop;
           repeat (30) @(posedge free_clk);
           chk(pclk_en === 1'b0, "pclk_en_o low after the stop");
           rd_levels(txl, rxl);
           for (i = 0; i < rxl; i = i + 1)
             begin
                rdv(R_RXDATA, v);
                got_rx[i] = v;
                repeat (5 + ($urandom % 10)) @(posedge free_clk);
             end
           rx_check(rxl, 1'b0, 2'd0);
        end
      if (TX_EN != 0)
        begin
           for (i = 0; i < TX_DEPTH; i = i + 1) begin wr(R_TXDATA, i); repeat (3) @(posedge free_clk); end
           wr(R_CMD, 32'h1);
           repeat (7) @(posedge free_clk);
           exp_tx_n = 0;
           for (i = 0; i < ((TX_DEPTH < 4) ? TX_DEPTH : 4); i = i + 1)
             begin
                tx_push_random(1, 1'b0);
                repeat (9) @(posedge free_clk);
             end
           i2s_setup(1, 3'd0, F_I2S, 1'b0);
           mon_clear;
           i2s_start(C_TX_ON);
           wait_frames(exp_tx_n + 2);
           i2s_stop;
           tx_check(exp_tx_n);
        end
      stimulus_done = 1;
   end
