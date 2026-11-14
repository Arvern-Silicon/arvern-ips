//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    xfer_abort
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : xfer_abort.v
// Module Description : Software control transfers ended early.
//                      CMD.XFER_ABORT right after XFER_START, after the
//                      SETUP before the first IN, with XFER.PKT set between
//                      IN packets, right after an XFER_NEXT, at the start of
//                      an OUT stage, between OUT packets, and in a status
//                      stage the device NAKs (OUT and IN): RESULT ABORTED,
//                      XFER_DONE, XFER_BUSY low, the port in RUN and polling
//                      resumed (a report is delivered). Then CMD.RESTART, a
//                      disconnect and CTRL.EN = 0 during a transfer: it ends
//                      at once with RESULT DETACHED, XFER_BUSY low and
//                      XFER_DONE (DETACH too on the disconnect).
//
// Doc "Control transfers", "States", "Register map".
//----------------------------------------------------------------------------

reg [31:0] xa_v;
reg [31:0] xa_p;
reg  [6:0] xa_len;
reg  [7:0] xa_seq;
reg [63:0] xa_d;
integer    xa_n;
integer    xa_k;

// Wait until IRQ_PEND & mask is non-zero (irq_o with IRQ_EN = mask), at
// most ms; pend returns IRQ_PEND
task xa_wait;
   input  [31:0] mask;
   input    real ms;
   output [31:0] pend;
   reg           to;
   integer       k;
   begin
      to = 1'b0;
      wr(R_IRQ_EN, mask);
      if (irq !== 1'b1)
        begin : w
           fork
              begin : w_ev
                 wait (irq === 1'b1);
                 disable w_to;
              end
              begin : w_to
                 for (k = 0; k < ms * 100.0; k = k + 1)
                   #(10.0e3);
                 to = 1'b1;
                 disable w_ev;
              end
           join
        end
      rdv(R_IRQ_PEND, pend);
      if (to)
        begin
           $display("ERROR: IRQ_PEND 0x%h: no bit of 0x%h within %0.1f ms %t ns", pend, mask, ms, $time);
           error = error + 1;
        end
   end
endtask

// A quiet bus point: after a keep-alive (a host drive shorter than 5 us),
// host and device both silent for 40 us
task xa_quiet;
   input real ms;
   real       t0;
   reg        ok;
   integer    n;
   integer    k;
   begin : q
      ok = 1'b0;
      fork
         begin : q_ev
            while (!ok)
              begin
                 @(posedge usb_oe);
                 t0 = $realtime;
                 @(negedge usb_oe);
                 if ($realtime - t0 < 5000.0) ok = 1'b1;
              end
            n = 0;
            while (n < 40)
              begin
                 #(1000.0);
                 n = ((usb_oe === 1'b0) && (dev.drv_en === 1'b0)) ? n + 1 : 0;
              end
            disable q_to;
         end
         begin : q_to
            for (k = 0; k < ms * 100.0; k = k + 1)
              #(10.0e3);
            ok = 1'b0;
            disable q_ev;
         end
      join
      if (!ok)
        begin
           $display("ERROR: no keep-alive within %0.1f ms (STATE %0s) %t ns", ms, st_name(tb_state), $time);
           error = error + 1;
        end
   end
endtask

// Start a transfer
task xa_start;
   input [31:0] s0;
   input [31:0] s1;
   begin
      wr(R_IRQ_PEND, I_XFER_PKT | I_XFER_DONE);
      wr(R_SETUP0, s0);
      wr(R_SETUP1, s1);
      wr(R_CMD, K_XFER_START);
   end
endtask

// XFER.PKT set (polled every 100 us, at most ms)
task xa_wait_pkt;
   input real ms;
   real       t0;
   begin
      t0 = $realtime;
      rdv(R_XFER, xa_v);
      while ((xa_v[8] !== 1'b1) && (($realtime - t0) < ms * T_MS))
        begin
           #(100.0e3);
           rdv(R_XFER, xa_v);
        end
      if (xa_v[8] !== 1'b1)
        begin
           $display("ERROR: XFER.PKT not set within %0.1f ms (XFER 0x%h) %t ns", ms, xa_v, $time);
           error = error + 1;
        end
   end
endtask

// The device accepted a new SETUP (st_xfer_start moved from n0), polled
// every 1 us, at most ms
task xa_wait_setup;
   input integer n0;
   input real    ms;
   real          t0;
   begin
      t0 = $realtime;
      while ((dev.st_xfer_start == n0) && (($realtime - t0) < ms * T_MS))
        #(1000.0);
      chk(dev.st_xfer_start != n0,     "the device accepted the SETUP");
   end
endtask

// The first IN data packet: XFER_PKT
task xa_first_pkt;
   begin
      xa_wait(I_XFER_PKT | I_XFER_DONE, 20.0, xa_p);
      chk32(xa_p & (I_XFER_PKT | I_XFER_DONE), I_XFER_PKT, "IRQ_PEND after an IN data packet");
      wr(R_IRQ_PEND, I_XFER_PKT);
   end
endtask

// XFER_ABORT, then XFER_DONE with RESULT ABORTED at the next packet
// boundary (the doc gives no bound: 5 ms, a few frames), XFER_BUSY low,
// the port in RUN, polling resumed
task xa_abort;
   begin
      wr(R_CMD, K_XFER_ABORT);
      xa_wait(I_XFER_DONE, 5.0, xa_p);
      chk((xa_p & I_XFER_DONE) != 0,   "XFER_DONE after XFER_ABORT");
      rdv(R_XFER, xa_v);
      chk32(xa_v & 32'hE00, {20'h0, X_ABORTED, 9'h0}, "XFER.RESULT ABORTED");
      rdv(R_STATUS, xa_v);
      chk(!f_xbusy(xa_v),              "XFER_BUSY falls after XFER_ABORT");
      chk(f_state(xa_v) == S_RUN,      "RUN after XFER_ABORT");
      chk(f_attempt(xa_v) == 2'd0 && f_err(xa_v) == E_NONE, "an abort is no failure");
      wr(R_IRQ_PEND, I_XFER_PKT | I_XFER_DONE);
      read_report(xa_len, xa_seq, xa_d);
      dev.push_report(8, 64'h0000_1700_0000_0001 + xa_seq);
      expect_report(xa_seq, 8, 64'h0000_1700_0000_0001 + xa_seq, 30.0);
   end
endtask

// A transfer ended at once by an event (RESTART, disconnect, EN = 0):
// RESULT DETACHED, XFER_DONE, XFER_BUSY low
task xa_detached;
   begin
      rdv(R_IRQ_PEND, xa_p);
      chk((xa_p & I_XFER_DONE) != 0,   "XFER_DONE at once");
      rdv(R_XFER, xa_v);
      chk32(xa_v & 32'hE00, {20'h0, X_DETACHED, 9'h0}, "XFER.RESULT DETACHED");
      rdv(R_STATUS, xa_v);
      chk(!f_xbusy(xa_v),              "XFER_BUSY falls at once");
   end
endtask

initial
   begin
      wait_reset_done(5);
      if (CTRL_EN == 0) tb_skip("CTRL_EN = 0: no software control transfers");

      enumerate(dev.P_KBD, C_EN | C_BOOT | C_IDLE0, 600.0);
      wait_ms(25.0);
      status_chk(S_RUN, E_NONE, 4'd0);
      wr(R_IRQ_PEND, I_ALL);

      // An aborted transfer is legally abandoned before its status stage;
      // the model keeps it open and its STATUS checker would count the next
      // SETUP: off until a completed transfer follows the aborts
      dev.chk_enable(dev.C_STATUS, 0);

      // Right after XFER_START
      xa_start(32'h0100_0680, 32'h0012_0000);
      xa_abort;

      // After the SETUP, before the first IN packet
      xa_n = dev.st_xfer_start;
      xa_start(32'h0100_0680, 32'h0012_0000);
      xa_wait_setup(xa_n, 5.0);
      xa_abort;

      // With PKT set, between IN packets
      xa_start(32'h0100_0680, 32'h0012_0000);
      xa_first_pkt;
      xa_abort;

      // Right after XFER_NEXT (the next IN pending or in flight)
      xa_start(32'h0302_0680, 32'h00FF_0409);
      xa_first_pkt;
      wr(R_CMD, K_XFER_NEXT);
      xa_abort;

      // OUT stage start: PKT set, nothing sent yet
      xa_start(32'h0200_0921, 32'h000C_0000);
      xa_wait_pkt(20.0);
      xa_abort;
      chk(dev.ctl_out_cnt == 0,        "no OUT data sent after an abort at the stage start");

      // Between OUT packets: the first of two accepted
      xa_start(32'h0200_0921, 32'h000C_0000);
      xa_wait_pkt(20.0);
      wr(R_XDATA0,     32'h0403_0201);
      wr(R_XDATA0 + 4, 32'h0807_0605);
      wr(R_XFER, 32'h8);
      wr(R_IRQ_PEND, I_XFER_PKT);
      wr(R_CMD, K_XFER_NEXT);
      xa_wait(I_XFER_PKT | I_XFER_DONE, 20.0, xa_p);
      chk32(xa_p & (I_XFER_PKT | I_XFER_DONE), I_XFER_PKT, "XFER_PKT after the first OUT packet");
      chk(dev.ctl_out_cnt == 8,        "first OUT packet received");
      wr(R_IRQ_PEND, I_XFER_PKT);
      xa_n = dev.srep_cnt;
      xa_abort;
      chk(dev.srep_cnt == xa_n,        "the aborted SET_REPORT was not completed");

      // Status stage OUT of an IN transfer, NAKed by the device: string 1,
      // wLength 8 (one packet ends the data stage)
      dev.inject_fault(dev.F_NAK, dev.T_OUT, 0, 6, 3, dev.ST_STATUS, 0, 30, 0);
      xa_start(32'h0301_0680, 32'h0008_0409);
      xa_first_pkt;
      wr(R_CMD, K_XFER_NEXT);
      for (xa_k = 0; (xa_k < 100) && (dev.fr_hits[0] < 2); xa_k = xa_k + 1)
        wait_ms(0.1);
      chk(dev.fr_hits[0] >= 2,         "status stage OUT NAKed");
      xa_abort;
      dev.clear_faults;

      // Status stage IN of a no-data request, NAKed: SET_IDLE(0)
      dev.inject_fault(dev.F_NAK, dev.T_IN, 0, 8'h0A, -1, dev.ST_STATUS, 0, 30, 0);
      xa_start(32'h0000_0A21, 32'h0000_0000);
      for (xa_k = 0; (xa_k < 100) && (dev.fr_hits[0] < 2); xa_k = xa_k + 1)
        wait_ms(0.1);
      chk(dev.fr_hits[0] >= 2,         "status stage IN NAKed");
      xa_abort;
      dev.clear_faults;

      // A complete transfer after the aborts, then the STATUS checker back on
      xa_start(32'h0100_0680, 32'h0008_0000);
      xa_first_pkt;
      rdv(R_XFER, xa_v);
      chk32(xa_v & 32'hE00, {20'h0, X_OK, 9'h0}, "XFER_START cleared the ABORTED result");
      wr(R_CMD, K_XFER_NEXT);
      xa_wait(I_XFER_PKT | I_XFER_DONE, 20.0, xa_p);
      chk32(xa_p & (I_XFER_PKT | I_XFER_DONE), I_XFER_DONE, "XFER_DONE of the transfer after the aborts");
      rdv(R_XFER, xa_v);
      chk32(xa_v & 32'hF00, {20'h0, X_OK, 9'h0}, "XFER.RESULT OK after the aborts");
      chk(dev.ctl_stage == dev.CS_DONE, "the transfer completed on the bus");
      wr(R_IRQ_PEND, I_XFER_PKT | I_XFER_DONE);
      dev.chk_enable(dev.C_STATUS, 1);

      // CMD.RESTART at the start of an OUT stage: DETACHED at once. The bus
      // reset abandons the open transfer (STATUS checker off until RECOVERY)
      dev.chk_enable(dev.C_STATUS, 0);
      xa_start(32'h0200_0921, 32'h0001_0000);
      xa_wait_pkt(20.0);
      xa_quiet(2.0);
      wr(R_IRQ_PEND, I_DETACH);
      wr(R_CMD, K_RESTART);
      wait_state(S_RESET, 2.0);
      xa_detached;
      chk((xa_p & I_DETACH) == 0,      "no DETACH on a RESTART");
      wait_state(S_RECOVERY, 62.0);
      dev.chk_enable(dev.C_STATUS, 1);
      wait_state(S_RUN, 300.0);
      wait_ms(25.0);
      wr(R_IRQ_PEND, I_ALL);

      // A disconnect with PKT set between IN packets: DETACHED at once,
      // DETACH. The model's detach clears its control pipe
      xa_start(32'h0100_0680, 32'h0012_0000);
      xa_first_pkt;
      xa_quiet(2.0);
      dev.detach;
      wait_state(S_DETACHED, 0.05);
      xa_detached;
      chk((xa_p & I_DETACH) != 0,      "DETACH on a disconnect in RUN");
      wr(R_IRQ_PEND, I_ALL);
      wait_ms(2.0);
      dev.attach(dev.P_KBD);
      wait_state(S_RUN, 600.0);
      wait_ms(25.0);
      wr(R_IRQ_PEND, I_ALL);

      // CTRL.EN = 0 while the device NAKs the data stage: DETACHED at once.
      // No bus reset follows, so the open transfer is never abandoned on
      // the bus as the model sees it
      dev.inject_fault(dev.F_NAK, dev.T_IN, 0, 6, 3, dev.ST_DATA, 0, -1, 0);
      xa_start(32'h0302_0680, 32'h00FF_0409);
      for (xa_k = 0; (xa_k < 100) && (dev.fr_hits[0] < 3); xa_k = xa_k + 1)
        wait_ms(0.1);
      chk(dev.fr_hits[0] >= 3,         "data stage NAKed");
      xa_quiet(2.0);
      wr(R_IRQ_PEND, I_DETACH);
      wr(R_CTRL, CTRL_RST);
      wait_state(S_OFF, 0.02);
      xa_detached;
      chk((xa_p & I_DETACH) == 0,      "no DETACH on CTRL.EN = 0");
      dev.clear_faults;
      stimulus_done = 1;
   end
