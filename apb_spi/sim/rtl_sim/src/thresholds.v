//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    thresholds
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : thresholds.v
// Module Description : Thresholds and the interrupt line: TX_LOW follows
//                      transmit level <= TX_THR, RX_HIGH receive level >=
//                      RX_THR with RX_THR >= 1 (0 disables it), irq_o is the
//                      OR of IRQ_PEND & IRQ_EN for level and sticky causes,
//                      through IRQ_EN and its aliases.
//
// Doc "IRQ_PEND".
//----------------------------------------------------------------------------

integer    i;
reg [31:0] v;

initial
   begin
      wait_reset_done(5);
      clk_set(1, 0);
      cs_set(8'h00, 1, 1, 1);
      ctrl_wr(C_IDLE_HIGH);                     // EN clear: entries wait
      wr(R_THRESH, 32'h0000_0002);
      wr(R_IRQ_EN, I_TX_LOW);
      chk(irq === 1'b1, "TX_LOW with an empty FIFO");
      for (i = 0; i < 3 && i < TX_DEPTH; i = i + 1) ent_tx(8, i, 1'b0);
      if (TX_DEPTH > 2) chk(irq === 1'b0, "TX_LOW clears above TX_THR");
      ctrl_wr(C_EN | C_IDLE_HIGH);
      wait_idle(10000);
      chk(irq === 1'b1, "TX_LOW again once drained");
      wr(R_THRESH, {7'h0, 9'h0, 7'h0, TX_DEPTH[8:0]});
      chk(irq === 1'b1, "TX_THR >= depth: TX_LOW permanent");
      wr(R_IRQ_EN_CLR, I_TX_LOW);
      chk(irq === 1'b0, "IRQ_EN_CLR masks it");
      if (RX_EN != 0)
        begin
           wr(R_THRESH, 32'h0004_0000);
           wr(R_IRQ_EN_SET, I_RX_HIGH);
           ent_drain = 0;
           for (i = 0; i < 4; i = i + 1) rq_push(i);
           ent_rx(8, (RX_DEPTH < 4) ? RX_DEPTH : 3, 1'b0);
           wait_idle(10000);
           chk(irq === 1'b0, "RX_HIGH below RX_THR");
           if (RX_DEPTH >= 4)
             begin
                ent_rx(8, 1, 1'b0);
                wait_idle(10000);
                chk(irq === 1'b1, "RX_HIGH at RX_THR");
                rdv(R_IRQ_PEND, v);
                chk(v[1] === 1'b1, "IRQ_PEND.RX_HIGH");
             end
           wr(R_THRESH, 32'h0000_0000);
           chk(irq === 1'b0, "RX_THR = 0 disables RX_HIGH");
           ent_drain = 1;
           rx_drain;
           wr(R_IRQ_EN, 32'h0);
        end
      // a sticky cause through IRQ_EN
      wr(R_IRQ_PEND, 32'h7C);
      wr(R_IRQ_EN, I_DONE);
      ent_tx(8, 32'h5A, 1'b0);
      wait_idle(10000);
      chk(irq === 1'b1, "DONE raises irq_o");
      wr(R_IRQ_PEND, I_DONE);
      chk(irq === 1'b0, "W1C clears it");
      wr(R_IRQ_EN, 32'h0);
      stimulus_done = 1;
   end
