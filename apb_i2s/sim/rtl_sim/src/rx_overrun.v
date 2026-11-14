//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    rx_overrun
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : rx_overrun.v
// Module Description : Receive overrun: with nobody reading, the FIFO fills,
//                      further words are dropped and RX_OVER is set (sticky,
//                      RW1C, irq_o when enabled); the words kept are the
//                      first, consecutive; after draining, reception goes
//                      on.
//
// Doc "Transmit and receive", "Interrupts".
//----------------------------------------------------------------------------

reg [31:0] v;
integer txl, rxl;

initial
   begin
      wait_reset_done(5);
      if (RX_EN == 0) tb_skip("no receive path");
      i2s_setup(1, 3'd0, F_I2S, 1'b0);
      wr(R_IRQ_EN, I_RX_OVER);
      i2s_start(C_RX_ON);
      rx_wait_level(RX_DEPTH);
      wait_frames(3);
      rdv(R_IRQ_PEND, v);
      chk(v[3] === 1'b1, "RX_OVER set with the FIFO full");
      chk(irq === 1'b1, "irq_o raised by RX_OVER");
      // drained while the stream runs: the words kept are the first ones
      rx_read(RX_DEPTH);
      rx_check(RX_DEPTH, 1'b0, 2'd0);
      wr(R_IRQ_PEND, I_RX_OVER);
      chk(irq === 1'b0, "irq_o low after the clear");
      // reception goes on
      rd_levels(txl, rxl);
      rx_read(rxl);
      rx_wait_level(2);
      rx_read(2);
      rx_check(2, 1'b0, 2'd0);
      rdv(R_IRQ_PEND, v);
      chk(v[3] === 1'b0, "no overrun once drained");
      i2s_stop;
      wr(R_CMD, 32'h2);
      wr(R_IRQ_EN, 0);
      stimulus_done = 1;
   end
