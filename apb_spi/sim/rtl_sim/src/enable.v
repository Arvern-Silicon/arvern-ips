//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    enable
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : enable.v
// Module Description : CTRL.EN: cleared during a long receive entry, the
//                      entry completes (every frame, its hold and release)
//                      and no further entry is taken; set again, the queued
//                      entries run; cleared inside a POLL pause, the poll
//                      completes; DONE only once the bus is idle with the
//                      FIFO empty.
//
// Doc "Transmit, receive and status" (EN).
//----------------------------------------------------------------------------

integer    i, f0, t0;
reg [31:0] v;

initial
   begin
      wait_reset_done(5);
      cs_set(8'h00, 1, 1, 1);
      spi_setup(C_IDLE_HIGH, 2, 0);
      for (i = 0; i < 20; i = i + 1) rq_push($urandom);
      if (RX_EN != 0) ent_rx(8, 20, 1'b0); else ent(xa(KDUMMY, 8, 1, 1'b0, 1'b0, 1'b0, 0), 159);
      ent_tx(8, 32'h11, 1'b0);
      repeat (40) @(posedge free_clk);
      f0 = n_frames; t0 = n_txn;
      wr(R_IRQ_PEND, 32'h7C);
      wr(R_CTRL_CLR, C_EN);
      wait_quiet(100000);
      repeat (50) @(posedge free_clk);
      chk(apb_spi_inst0.tx_level == 1, "the next entry waits");
      chk(spi_cs === {CS_NR{1'b1}}, "the entry in progress released its select");
      rdv(R_STATUS, v);
      chk(v[30] === 1'b0, "not IDLE with an entry waiting");
      irq_chk(32'h0, I_DONE);
      wr(R_CTRL_SET, C_EN);
      wait_idle(100000);
      rx_drain;
      chk(n_txn == t0 + 1, "the waiting entry ran once EN was set");
      irq_chk(I_DONE, I_DONE);
      if (POLL_USE)
        begin
           dev_rt = 295.0;
           clk_set(1, 15);
           for (i = 0; i < 6; i = i + 1) rq_push(32'hFF);
           rq_push(32'hFE);
           ent(xa(KPOLL, 8, 1, 1'b0, 1'b0, 1'b0, 0), {8'hFF, 8'hFF, 16'd20});
           wait (apb_spi_inst0.u_core.st == 3'd3);
           wr(R_CTRL_CLR, C_EN);
           wait_idle(100000);
           rx_drain;
           chk32(rx_got[x_rd - 1], 32'hFE, "the poll completed with EN cleared");
           dev_rt = 0.0;
        end
      stimulus_done = 1;
   end
