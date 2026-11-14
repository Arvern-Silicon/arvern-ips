//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    flush
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : flush.v
// Module Description : FIFO flushes (CMD): with the stream running and with
//                      it stopped, a transmit flush empties the FIFO and the
//                      mono half pointer (the frame in progress is still
//                      sent, then zeros), a receive flush empties the FIFO
//                      and a held mono sample; the sticky flags are kept;
//                      CMD reads 0.
//
// Doc "Register map" (CMD), "Stream state".
//----------------------------------------------------------------------------

integer txl, rxl;
reg [31:0] v;

initial
   begin
      wait_reset_done(5);
      rd(R_CMD, 32'h0);
      if (TX_EN != 0)
        begin
           i2s_setup(1, 3'd0, F_I2S, 1'b0);
           ctrl_wr(t_ctrl | C_TX_MONO);
           exp_tx_n = 0;
           tx_push_random(TX_DEPTH, 1'b1);
           i2s_start(C_TX_ON);
           while (tb_tx_half !== 1'b1) @(posedge free_clk);
           #1;
           wr(R_CMD, 32'h1);
           rd_levels(txl, rxl);
           chk(txl == 0, "TX flush empties the FIFO while running");
           chk(tb_tx_half === 1'b0, "TX flush clears the mono half pointer");
           wait_frames(2);
           rdv(R_IRQ_PEND, v);
           chk(v[2] === 1'b1, "TX_UNDER after the flush (kept by the flush)");
           wr(R_CMD, 32'h1);
           rdv(R_IRQ_PEND, v);
           chk(v[2] === 1'b1, "TX flush keeps TX_UNDER");
           i2s_stop;
           wr(R_IRQ_PEND, I_TX_UNDER);
           ctrl_wr(t_ctrl & ~C_TX_MONO);
        end
      if (RX_EN != 0)
        begin
           i2s_setup(1, 3'd0, F_I2S, 1'b0);
           ctrl_wr(t_ctrl | C_RX_MONO);
           i2s_start(C_RX_ON);
           rx_wait_level((RX_DEPTH < 3) ? RX_DEPTH : 3);
           while (tb_rx_half !== 1'b1) @(posedge free_clk);
           #1;
           wr(R_CMD, 32'h2);
           rd_levels(txl, rxl);
           chk(rxl == 0, "RX flush empties the FIFO while running");
           chk(tb_rx_half === 1'b0, "RX flush drops the held mono sample");
           i2s_stop;
           wr(R_CMD, 32'h2);
           ctrl_wr(t_ctrl & ~C_RX_MONO);
        end
      stimulus_done = 1;
   end
