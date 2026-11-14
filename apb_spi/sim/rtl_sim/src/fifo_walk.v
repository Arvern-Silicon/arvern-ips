//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    fifo_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : fifo_walk.v
// Module Description : FIFO walk: the transmit FIFO filled to its depth with
//                      entries of all-zero attributes and payload, then of the
//                      most ones a legal entry carries (POLL or DUMMY, the
//                      widest lanes, 32-bit frames, CAPT, CS_HOLD, CS_NONE,
//                      select 7, payload all ones), then zeros again, then a
//                      dual-lane variant, then zeros, flushed each time, so
//                      every storage bit rises and falls; the same patterns
//                      pushed while the engine runs, the write pointer
//                      wrapping with the FIFO full (the last storage word);
//                      then one random fill run through the engine. The receive FIFO filled to its
//                      depth with all-ones then all-zeros words, read back in
//                      order. Levels checked against the depth at every fill.
//
// Doc "Transmit, receive and status".
//----------------------------------------------------------------------------

integer    r, i, lanes_w;
reg [15:0] x_zero, x_ones, x_dual;
reg [31:0] v;

task tx_fill;                                 // fill the transmit FIFO with one entry pattern, then flush
   input [15:0] x;
   input [31:0] d;
   begin
      for (i = 0; i < TX_DEPTH; i = i + 1) ent(x, d);
      chk(apb_spi_inst0.tx_level == TX_DEPTH, "transmit FIFO full");
      wr(R_CMD, K_TX_FLUSH);
      chk(apb_spi_inst0.tx_level == 0, "transmit FIFO flushed");
   end
endtask

task rx_fill;                                 // fill the receive FIFO with one word, read it back
   input [31:0] w;
   begin
      for (i = 0; i < RX_DEPTH; i = i + 1) rq_push(w);
      ent_rx(32, RX_DEPTH, 1'b0);
      wait_idle(400000);
      chk(apb_spi_inst0.rx_level == RX_DEPTH, "receive FIFO full");
      rx_pop_chk(RX_DEPTH);
   end
endtask

initial
   begin
      wait_reset_done(5);
      ent_drain = 0;
      clk_set(1, 0);
      ctrl_wr(C_IDLE_HIGH);                     // EN clear: entries stay queued
      lanes_w = (LANES_MAX == 4) ? 4 : (LANES_MAX == 2) ? 2 : 1;
      x_zero  = xa(KTX, 1, 1, 1'b0, 1'b0, 1'b0, 0);
      x_ones  = xa(POLL_USE ? KPOLL : KDUMMY, 32, lanes_w, RX_EN != 0, 1'b1, 1'b1, 7);
      x_dual  = xa(POLL_USE ? KPOLL : KDUMMY, 32, (LANES_MAX >= 2) ? 2 : 1, RX_EN != 0, 1'b1, 1'b1, 7);
      tx_fill(x_zero, 32'h0000_0000);
      tx_fill(x_ones, 32'hFFFF_FFFF);
      tx_fill(x_zero, 32'h0000_0000);
      tx_fill(x_dual, 32'hFFFF_FFFF);
      tx_fill(x_zero, 32'h0000_0000);
      // the write pointer wrapping with the FIFO kept full, so the last storage
      // word is written too: the ones pattern (a POLL met on its first frame,
      // the device answering zeros), zeros, the dual-lane ones pattern, zeros,
      // the ones pattern, zeros, a FIFO's worth each, while the engine runs
      ctrl_wr(C_EN | C_IDLE_HIGH);
      if (POLL_USE)
        begin
           ent_drain = 1;
           rq_dflt   = 32'h0;
           // each round wraps the write pointer once; the last storage word
           // takes the first push of every round after the first
           for (r = 0; r < 6; r = r + 1)
             for (i = 0; i < TX_DEPTH; i = i + 1)
               ent((r % 2) ? x_zero : (r % 4 == 0) ? x_ones : x_dual, (r % 2) ? 32'h0000_0000 : 32'hFFFF_FFFF);
           wait_idle(4000000);
           rx_drain;
           rq_dflt   = 32'hFFFF_FFFF;
           ent_drain = 0;
        end
      // one random fill through the engine
      for (r = 0; r < TX_DEPTH; r = r + 1) ent_tx(32, $urandom, 1'b0);
      wait_idle(400000);
      if (RX_EN != 0)
        begin
           rx_fill(32'hFFFF_FFFF);
           rx_fill(32'h0000_0000);
        end
      ent_drain = 1;
      stimulus_done = 1;
   end
