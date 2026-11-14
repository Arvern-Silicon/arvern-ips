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
// Module Description : FIFO level interrupts: TX_LOW (level <= TX_THR) and
//                      RX_HIGH (level >= RX_THR > 0) as live levels at every
//                      level from empty to full, the threshold extremes
//                      (TX_THR 0, depth - 1, >= depth; RX_THR 0, depth,
//                      > depth), irq_o gated by IRQ_EN, writes of 1 to the
//                      level bits ignored, THRESH stored on 9 bits.
//
// Doc "Interrupts" (IRQ_PEND TX_LOW / RX_HIGH), "Register map" (THRESH).
//----------------------------------------------------------------------------

integer lv, thr, ti, txl, rxl, i;
integer tl [0:3];
reg [31:0] v;

initial
   begin
      wait_reset_done(5);
      if (TX_EN != 0)
        begin
           tl[0] = 0; tl[1] = TX_DEPTH - 1; tl[2] = TX_DEPTH; tl[3] = 511;
           for (ti = 0; ti < 4; ti = ti + 1)
             begin
                wr(R_THRESH, tl[ti]);
                rd(R_THRESH, tl[ti]);
                wr(R_CMD, 32'h1);
                for (lv = 0; lv <= TX_DEPTH; lv = lv + 1)
                  begin
                     rdv(R_IRQ_PEND, v);
                     chk(v[0] === (lv <= tl[ti]), "TX_LOW = level <= TX_THR");
                     if (lv < TX_DEPTH) wr(R_TXDATA, 32'h1234 + lv);
                  end
             end
           wr(R_CMD, 32'h1);
           wr(R_THRESH, 32'h0);
           wr(R_IRQ_EN, I_TX_LOW);
           chk(irq === 1'b1, "irq_o from TX_LOW with IRQ_EN");
           wr(R_IRQ_PEND, 32'h3);
           rdv(R_IRQ_PEND, v);
           chk(v[0] === 1'b1, "writing 1 to TX_LOW does not clear the level");
           wr(R_IRQ_EN, 0);
           chk(irq === 1'b0, "irq_o masked by IRQ_EN");
        end
      if (RX_EN != 0)
        begin
           i2s_setup(1, 3'd0, F_I2S, 1'b0);
           rx_fill(RX_DEPTH);
           tl[0] = 0; tl[1] = 1; tl[2] = RX_DEPTH; tl[3] = RX_DEPTH + 1;
           for (lv = RX_DEPTH; lv >= 0; lv = lv - 1)
             begin
                for (ti = 0; ti < 4; ti = ti + 1)
                  begin
                     wr(R_THRESH, tl[ti] << 16);
                     rdv(R_IRQ_PEND, v);
                     chk(v[1] === ((tl[ti] != 0) && (lv >= tl[ti])), "RX_HIGH = level >= RX_THR > 0");
                  end
                if (lv == 1)
                  begin
                     wr(R_THRESH, 32'h00010000);
                     wr(R_IRQ_EN, I_RX_HIGH);
                     chk(irq === 1'b1, "irq_o from RX_HIGH with IRQ_EN");
                     wr(R_IRQ_EN, 0);
                  end
                if (lv > 0) rdv(R_RXDATA, v);
             end
           wr(R_THRESH, 32'h0);
        end
      stimulus_done = 1;
   end
