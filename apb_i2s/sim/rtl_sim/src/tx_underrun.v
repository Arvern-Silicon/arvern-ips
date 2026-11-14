//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tx_underrun
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tx_underrun.v
// Module Description : Transmit underrun: TX_ON with an empty FIFO sends
//                      zero frames and sets TX_UNDER (sticky, RW1C, raises
//                      irq_o when enabled); a word written later is sent at
//                      the next boundary; a W1C in the cycle of a new
//                      underrun leaves the bit set.
//
// Doc "Transmit and receive", "Interrupts" (IRQ_PEND, IRQ_EN).
//----------------------------------------------------------------------------

reg [31:0] v;
integer    off;

initial
   begin
      wait_reset_done(5);
      if (TX_EN == 0) tb_skip("no transmit path");
      i2s_setup(1, 3'd0, F_I2S, 1'b0);
      wr(R_IRQ_EN, I_TX_UNDER);
      mon_clear;
      i2s_start(C_TX_ON);
      wait_frames(2);
      rdv(R_IRQ_PEND, v);
      chk(v[2] === 1'b1, "TX_UNDER set by an empty FIFO");
      chk(irq === 1'b1, "irq_o raised by TX_UNDER");
      // W1C in the cycle of a new underrun (frame boundary): the bit stays set
      for (off = 0; off < 6; off = off + 1)
        begin
           while (!((apb_i2s_inst0.u_core.pos == 6'd63) && apb_i2s_inst0.u_core.bhigh &&
                    (apb_i2s_inst0.u_core.bcnt == 5'd0))) @(posedge free_clk);
           #1;
           repeat (off) @(posedge free_clk);
           #1;
           wr(R_IRQ_PEND, I_TX_UNDER);
           if (cv_w1c_race) off = 6;
        end
      rdv(R_IRQ_PEND, v);
      chk(v[2] === 1'b1, "TX_UNDER set again after the racing clear");
      exp_tx_n = 0;
      tx_push_random(1, 1'b0);
      wait_frames(3);
      wr(R_IRQ_PEND, I_TX_UNDER);
      i2s_stop;
      tx_check(1);
      wr(R_IRQ_PEND, I_TX_UNDER);
      rdv(R_IRQ_PEND, v);
      chk(v[2] === 1'b0, "TX_UNDER cleared by W1C");
      chk(irq === 1'b0, "irq_o low after the clear");
      wr(R_IRQ_EN, 0);
      stimulus_done = 1;
   end
