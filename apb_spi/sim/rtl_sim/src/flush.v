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
// Module Description : Flushes: TX_FLUSH empties the transmit FIFO with the
//                      engine disabled (DONE: IDLE rises), takes an entry
//                      waiting for receive room with it, and lets the entry
//                      in progress complete; RX_FLUSH empties the receive
//                      FIFO and frames still in flight arrive afterwards.
//
// Doc "Transmit, receive and status" (flush).
//----------------------------------------------------------------------------

integer    i, n0;

initial
   begin
      wait_reset_done(5);
      clk_set(1, 0);
      cs_set(8'h00, 1, 1, 1);
      ctrl_wr(C_IDLE_HIGH);
      for (i = 0; i < 3 && i < TX_DEPTH; i = i + 1) ent_tx(8, i, 1'b0);
      wr(R_IRQ_PEND, 32'h7C);
      wr(R_CMD, K_TX_FLUSH);
      chk(apb_spi_inst0.tx_level == 0, "TX_FLUSH empties the FIFO");
      wr(R_CMD, K_RX_FLUSH);                     // no effect without a receive path
      rd(R_STATUS, 32'h4000_0000);
      irq_chk(I_DONE, I_DONE);
      // the entry in progress completes
      ctrl_wr(C_EN | C_IDLE_HIGH);
      clk_set(4, 0);
      n0 = n_frames;
      ent(xa(KDUMMY, 8, 1, 1'b0, 1'b0, 1'b0, 0), 40);
      ent_tx(8, 32'h11, 1'b0);
      repeat (40) @(posedge free_clk);
      wr(R_CMD, K_TX_FLUSH);
      wait_idle(100000);
      chk(n_frames == n0 + 41, "the entry in progress completed, the next was flushed");
      if (RX_EN != 0)
        begin
           // an entry waiting for receive room is flushed
           ent_drain = 0;
           clk_set(1, 1);
           for (i = 0; i < RX_DEPTH; i = i + 1) rq_push(i);
           ent_rx(8, RX_DEPTH, 1'b0);
           wait_idle(100000);
           ent_rx(8, 1, 1'b0);
           repeat (50) @(posedge free_clk);
           chk(apb_spi_inst0.core_stall === 1'b1, "the entry waits for room");
           wr(R_CMD, K_TX_FLUSH);
           chk(apb_spi_inst0.tx_level == 0, "the waiting entry flushed");
           // RX_FLUSH, then a frame in flight arrives (receive delay 15, round trip 295 ns)
           wr(R_CMD, K_RX_FLUSH);
           chk(apb_spi_inst0.rx_level == 0, "RX_FLUSH empties the FIFO");
           dev_rt = 295.0;
           clk_set(1, 15);
           rq_push(32'h77);
           ent_rx(8, 1, 1'b0);
           wait (apb_spi_inst0.u_core.npend != 0);
           wr(R_CMD, K_RX_FLUSH);
           ent_drain = 1;
           wait_idle(100000);
           rx_drain;
           chk32(rx_got[x_rd - 1], 32'h77, "the frame in flight arrives after the flush");
           dev_rt = 0.0;
        end
      stimulus_done = 1;
   end
