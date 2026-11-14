//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    abort
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : abort.v
// Module Description : CMD.ABORT: during a transmit frame (it completes),
//                      inside a long receive entry and a long DUMMY (they
//                      end at the next frame / clock boundary, the frames
//                      clocked are delivered), inside a POLL pause and on an
//                      entry stalled between frames (they end at once),
//                      during SETUP (no clock edge, the select released
//                      after the hold time), with a held select and an idle
//                      bus under the gated clock (the release completes and
//                      sets DONE), and with nothing in progress (the queued
//                      entries are flushed, nothing else happens). The
//                      transmit FIFO is emptied every time; the next
//                      transaction runs normally.
//
// Doc "Transmit, receive and status" (abort).
//----------------------------------------------------------------------------

integer    sc, i, n0, f0;

task abort_now;
   begin
      wr(R_CMD, K_ABORT);
      chk(apb_spi_inst0.tx_level == 0, "ABORT empties the transmit FIFO");
      wait_idle(200000);
      rx_drain;
      chk(spi_cs === {CS_NR{1'b1}}, "select released");
      rq_rd = rq_wr;                          // responses of frames never clocked
   end
endtask

task after;                                   // a normal transaction afterwards
   begin
      ent_tx(8, 32'h5A, 1'b0);
      wait_idle(10000);
   end
endtask

initial
   begin
      wait_reset_done(5);
      abort_ok = 1;
      cs_set(8'h00, 1, 2, 1);
      // a transmit frame completes
      spi_setup(C_IDLE_HIGH, 8, 0);
      ent_tx(32, 32'hDEADBEEF, 1'b1); ent_tx(32, 32'h12345678, 1'b0);
      wait (apb_spi_inst0.u_core.st == 3'd2); repeat (20) @(posedge free_clk);
      n0 = n_frames;
      abort_now;
      chk(n_frames == n0 + 1, "the transmit frame in progress completed, the next was flushed");
      after;
      if (RX_EN != 0)
        begin
           // a receive entry ends at the next frame boundary
           for (i = 0; i < 40; i = i + 1) rq_push($urandom);
           ent_rx(8, 40, 1'b0);
           repeat (300) @(posedge free_clk);
           f0 = n_frames;
           abort_now;
           chk(n_frames < f0 + 3 && n_frames >= f0, "the receive entry ended at a frame boundary");
           after;
        end
      // a DUMMY ends at the next clock
      ent(xa(KDUMMY, 8, 1, 1'b0, 1'b0, 1'b0, 0), 999);
      repeat (300) @(posedge free_clk);
      f0 = n_frames;
      abort_now;
      chk(n_frames <= f0 + 2, "the DUMMY ended at the next clock");
      after;
      if (POLL_USE)
        begin
           // inside a POLL pause (RX_DLY 15, round trip 295 ns: a long pause at HALF 1)
           dev_rt = 295.0;
           clk_set(1, 15);
           for (i = 0; i < 100; i = i + 1) rq_push(32'hFF);
           ent(xa(KPOLL, 8, 1, 1'b0, 1'b0, 1'b0, 0), {8'hFF, 8'hFF, 16'd99});
           wait (apb_spi_inst0.u_core.st == 3'd3);
           wait (apb_spi_inst0.u_core.st == 3'd2);
           wait (apb_spi_inst0.u_core.st == 3'd3);
           #1 abort_now;
           rq_rd = rq_wr;
           dev_rt = 0.0;
           clk_set(8, 0);
           after;
        end
      if (RX_EN != 0)
        begin
           // an entry stalled between frames
           ent_drain = 0;
           for (i = 0; i < RX_DEPTH + 4; i = i + 1) rq_push($urandom);
           ent_rx(8, RX_DEPTH + 4, 1'b0);
           for (i = 0; i < 100000 && !apb_spi_inst0.core_stall; i = i + 1) @(posedge free_clk);
           repeat (20) @(posedge free_clk);
           ent_drain = 1;
           abort_now;
           rq_rd = rq_wr;
           after;
        end
      // during SETUP: no clock edge (a capturing entry: its reserved room is returned)
      cs_set(8'h00, 16, 2, 1);
      if (RX_EN != 0) ent_rx(8, 4, 1'b0); else ent_tx(8, 32'hA5, 1'b0);
      wait (apb_spi_inst0.u_core.st == 3'd1); repeat (10) @(posedge free_clk);
      n0 = t_nedge;
      abort_now;
      chk(t_nedge == 0, "no clock edge after an ABORT during SETUP");
      if (RX_EN != 0) chk(tb_inflight == 0, "the aborted frame's room returned");
      cs_set(8'h00, 1, 2, 1);
      after;
      // a held select, idle bus, gated clock
      ent_tx(8, 32'hC3, 1'b1);
      wait_quiet(10000);
      repeat (20) @(posedge free_clk);
      wr(R_IRQ_PEND, 32'h7C);
      abort_now;
      irq_chk(I_DONE, I_DONE);
      after;
      // nothing in progress: the queued entries are flushed
      ctrl_wr(C_IDLE_HIGH);
      ent_tx(8, 1, 1'b0); ent_tx(8, 2, 1'b0);
      n0 = n_txn;
      wr(R_CMD, K_ABORT);
      chk(apb_spi_inst0.tx_level == 0, "ABORT flushes queued entries");
      ctrl_wr(C_EN | C_IDLE_HIGH);
      repeat (50) @(posedge free_clk);
      chk(n_txn == n0, "nothing started");
      after;
      abort_ok = 0;
      stimulus_done = 1;
   end
