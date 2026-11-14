//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    xfer_errors
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : xfer_errors.v
// Module Description : Software control transfers that do not end OK.
//                      CMD.XFER_START outside RUN (OFF, DETACHED, DEBOUNCE,
//                      RESET, RECOVERY, ENUM, BACKOFF) and while a transfer
//                      runs: RESULT REFUSED and XFER_DONE at once, the
//                      enumeration and the running transfer undisturbed.
//                      CMD.XFER_NEXT with no transfer or while XFER.PKT is
//                      clear: ignored. A STALL in the data IN, the status IN
//                      or the data OUT: RESULT STALL, the port stays in RUN,
//                      ATTEMPT unchanged, polling unaffected. Two
//                      transaction errors in a data stage are retried (OK);
//                      three end it with ERROR, a failure (BACKOFF, ERR,
//                      STEP 0, ATTEMPT 1, re-enumeration). The device NAKing
//                      the data stage forever: ERROR after 500 to 501 ms
//                      (ERR progress timeout).
//
// Doc "Control transfers", "Transactions", "Attempts", "Register map".
//----------------------------------------------------------------------------

reg [31:0] xe_v;
reg [31:0] xe_p;
reg [31:0] xe_w0;
reg [31:0] xe_w1;
reg        xe_watch = 1'b0;
integer    xe_ka    = 0;                   // host keep-alives while xe_watch (drive < 5 us)
integer    xe_pk    = 0;                   // host packets while xe_watch (longer drives)
real       xe_t_oe  = 0.0;
real       xe_t_ev  = 0.0;                 // time xe_wait saw irq_o
reg  [6:0] xe_len;
reg  [7:0] xe_seq;
reg [63:0] xe_d;
integer    xe_n;

always @(posedge usb_oe)
  xe_t_oe = $realtime;

always @(negedge usb_oe)
  if (xe_watch)
    begin
       if (($realtime - xe_t_oe) < 5000.0) xe_ka = xe_ka + 1;
       else                                xe_pk = xe_pk + 1;
    end

// Wait until IRQ_PEND & mask is non-zero (irq_o with IRQ_EN = mask), at
// most ms; pend returns IRQ_PEND, xe_t_ev the time irq_o was seen
task xe_wait;
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
      xe_t_ev = $realtime;
      rdv(R_IRQ_PEND, pend);
      if (to)
        begin
           $display("ERROR: IRQ_PEND 0x%h: no bit of 0x%h within %0.1f ms %t ns", pend, mask, ms, $time);
           error = error + 1;
        end
   end
endtask

// CMD.XFER_START that must be refused: RESULT REFUSED and XFER_DONE at
// once; with a transfer running, XFER_BUSY, PKT, LEN and XDATA unchanged
task xe_refused;
   input        running;
   reg   [31:0] x0, a0, a1;
   begin
      rdv(R_XFER, x0);
      rdv(R_XDATA0, a0);
      rdv(R_XDATA0 + 4, a1);
      wr(R_IRQ_PEND, I_XFER_DONE);
      wr(R_CMD, K_XFER_START);
      rdv(R_XFER, xe_v);
      chk32(xe_v & 32'hE00, {20'h0, X_REFUSED, 9'h0}, "XFER.RESULT REFUSED at once");
      rdv(R_IRQ_PEND, xe_p);
      chk((xe_p & I_XFER_DONE) != 0,   "XFER_DONE at once on a refused XFER_START");
      rdv(R_STATUS, xe_v);
      chk(f_xbusy(xe_v) == running,    "XFER_BUSY unchanged by a refused XFER_START");
      if (running)
        begin
           rdv(R_XFER, xe_v);
           chk32(xe_v & 32'h17F, x0 & 32'h17F, "running transfer: XFER.PKT / LEN undisturbed");
           rd(R_XDATA0, a0);
           rd(R_XDATA0 + 4, a1);
        end
      wr(R_IRQ_PEND, I_XFER_DONE);
   end
endtask

// The port waits for software for ms: keep-alives only, PKT held
task xe_hold;
   input real ms;
   begin
      xe_ka    = 0;
      xe_pk    = 0;
      xe_watch = 1'b1;
      wait_ms(ms);
      xe_watch = 1'b0;
      chk(xe_pk == 0,                  "no packet while the port waits for XFER_NEXT");
      chk(xe_ka >= (ms - 1.0),         "a keep-alive in every frame while the port waits");
      rdv(R_XFER, xe_v);
      chk(xe_v[8] == 1'b1,             "XFER.PKT held until XFER_NEXT");
   end
endtask

// One IN data packet of len bytes, from byte off of region r
task xe_pkt;
   input integer len;
   input integer r;
   input integer off;
   integer       k;
   reg    [63:0] d;
   begin
      xe_wait(I_XFER_PKT | I_XFER_DONE, 20.0, xe_p);
      chk32(xe_p & (I_XFER_PKT | I_XFER_DONE), I_XFER_PKT, "IRQ_PEND after an IN data packet");
      rdv(R_XFER, xe_v);
      chk32(xe_v & 32'h17F, 32'h100 | len, "XFER.PKT and LEN after an IN data packet");
      rdv(R_XDATA0,     xe_w0);
      rdv(R_XDATA0 + 4, xe_w1);
      d = {xe_w1, xe_w0};
      for (k = 0; k < len; k = k + 1)
        if (d[8*k +: 8] !== dev.dmem[r*256 + off + k])
          begin
             $display("ERROR: XDATA byte %0d = 0x%h, expected descriptor byte %0d = 0x%h %t ns", k, d[8*k +: 8],
                      off + k, dev.dmem[r*256 + off + k], $time);
             error = error + 1;
          end
      wr(R_IRQ_PEND, I_XFER_PKT);
   end
endtask

// XFER_DONE with RESULT res, no further packet, XFER_BUSY low
task xe_done;
   input  [2:0] res;
   input   real ms;
   begin
      xe_wait(I_XFER_PKT | I_XFER_DONE, ms, xe_p);
      chk32(xe_p & (I_XFER_PKT | I_XFER_DONE), I_XFER_DONE, "XFER_DONE, no further data packet");
      rdv(R_XFER, xe_v);
      chk32(xe_v & 32'hE00, {20'h0, res, 9'h0}, "XFER.RESULT at XFER_DONE");
      rdv(R_STATUS, xe_v);
      chk(!f_xbusy(xe_v),              "XFER_BUSY falls at the end of the transfer");
      wr(R_IRQ_PEND, I_XFER_DONE);
   end
endtask

// Start a transfer
task xe_start;
   input [31:0] s0;
   input [31:0] s1;
   begin
      wr(R_IRQ_PEND, I_XFER_PKT | I_XFER_DONE);
      wr(R_SETUP0, s0);
      wr(R_SETUP1, s1);
      wr(R_CMD, K_XFER_START);
   end
endtask

// A STALLed request: STALL, the port in RUN, ATTEMPT and ERR unchanged, no
// FAIL, polling unaffected
task xe_stall_chk;
   reg [31:0] s0;
   begin
      rdv(R_STATUS, s0);
      chk(f_state(s0) == S_RUN,        "a STALLed transfer leaves the port in RUN");
      chk(f_attempt(s0) == 2'd0,       "a STALLed transfer is no failure (ATTEMPT)");
      chk(f_err(s0) == E_NONE,         "a STALLed transfer is no failure (ERR)");
      rdv(R_IRQ_PEND, xe_p);
      chk((xe_p & I_FAIL) == 0,        "no FAIL after a STALL");
      read_report(xe_len, xe_seq, xe_d);
      dev.push_report(8, 64'h0000_0700_0000_0001 + xe_seq);
      expect_report(xe_seq, 8, 64'h0000_0700_0000_0001 + xe_seq, 30.0);
   end
endtask

initial
   begin
      wait_reset_done(5);
      if (CTRL_EN == 0) tb_skip("CTRL_EN = 0: no software control transfers");
      wr(R_IRQ_PEND, I_ALL);

      // OFF, DETACHED: refused; XFER_NEXT with no transfer: ignored
      xe_refused(1'b0);
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0);
      wait_state(S_DETACHED, 1.0);
      wait_ms(1.0);
      xe_refused(1'b0);
      rdv(R_XFER, xe_w0);
      wr(R_CMD, K_XFER_NEXT);
      wait_ms(1.0);
      rd(R_XFER, xe_w0);
      rdv(R_IRQ_PEND, xe_p);
      chk((xe_p & (I_XFER_PKT | I_XFER_DONE)) == 0, "XFER_NEXT with no transfer: no XFER interrupt");

      // DEBOUNCE, RESET, RECOVERY, ENUM: refused, the enumeration undisturbed
      // (the model counts any extra SETUP during it)
      dev.attach(dev.P_KBD);
      wait_state(S_DEBOUNCE, 1.0);
      wait_ms(10.0);
      xe_refused(1'b0);
      wait_state(S_RESET, 102.0);
      wait_ms(10.0);
      xe_refused(1'b0);
      wait_state(S_RECOVERY, 62.0);
      wait_ms(2.0);
      xe_refused(1'b0);
      wait_state(S_ENUM, 12.0);
      xe_refused(1'b0);
      wait_state(S_RUN, 600.0);
      chk(!st_seen(S_BACKOFF),         "enumeration undisturbed by refused XFER_STARTs");
      wait_ms(25.0);
      status_chk(S_RUN, E_NONE, 4'd0);

      // RUN, no transfer: XFER_NEXT ignored (no SETUP, nothing raised)
      wr(R_IRQ_PEND, I_ALL);
      xe_n = dev.st_xfer_start;
      rdv(R_XFER, xe_w0);
      wr(R_CMD, K_XFER_NEXT);
      wait_ms(3.0);
      rd(R_XFER, xe_w0);
      rdv(R_IRQ_PEND, xe_p);
      chk((xe_p & (I_XFER_PKT | I_XFER_DONE)) == 0, "XFER_NEXT in RUN with no transfer: nothing raised");
      chk(dev.st_xfer_start == xe_n,   "XFER_NEXT with no transfer sends nothing");
      rdv(R_STATUS, xe_v);
      chk(!f_xbusy(xe_v),              "no transfer started by XFER_NEXT");

      // STALLs. A STALL ends the control transfer (USB 2.0 8.5.3.4); the
      // model keeps it open and its STATUS checker would count the next
      // SETUP as abandoning it: off until a later SETUP has been accepted.
      dev.chk_enable(dev.C_STATUS, 0);
      // Unknown standard request, IN data stage STALLed
      xe_start(32'h0000_3380, 32'h0008_0000);
      xe_done(X_STALL, 20.0);
      xe_stall_chk;
      // Unknown standard request, no data stage: status IN STALLed
      xe_start(32'h0000_3300, 32'h0000_0000);
      xe_done(X_STALL, 20.0);
      xe_stall_chk;
      // Unknown vendor request with an OUT data stage: the data OUT STALLed
      xe_start(32'h0000_3340, 32'h0002_0000);
      begin : st_out
         integer k;
         xe_v = 32'h0;
         for (k = 0; (k < 200) && (xe_v[8] !== 1'b1); k = k + 1)
           begin
              #(100.0e3);
              rdv(R_XFER, xe_v);
           end
         chk(xe_v[8] === 1'b1,         "OUT stage started (XFER.PKT)");
      end
      wr(R_XDATA0, 32'h0000_A55A);
      wr(R_XFER, 32'h2);
      wr(R_IRQ_PEND, I_XFER_PKT);
      wr(R_CMD, K_XFER_NEXT);
      xe_done(X_STALL, 20.0);
      xe_stall_chk;

      // XFER_NEXT right after XFER_START (PKT clear): ignored, packet 0
      // still waits. XFER_START while the transfer runs: REFUSED, the
      // transfer undisturbed. GET_DESCRIPTOR(DEVICE, 18)
      xe_n = dev.st_xfer_start;
      xe_start(32'h0100_0680, 32'h0012_0000);
      wr(R_CMD, K_XFER_NEXT);
      xe_pkt(8, dev.R_DEV, 0);
      rdv(R_XFER, xe_v);
      chk32(xe_v & 32'hE00, {20'h0, X_OK, 9'h0}, "XFER_START cleared the STALL result");
      xe_hold(3.0);
      xe_refused(1'b1);
      chk(dev.st_xfer_start == xe_n + 1, "no new SETUP from the refused XFER_START");
      dev.chk_enable(dev.C_STATUS, 1);
      xe_hold(2.0);
      wr(R_CMD, K_XFER_NEXT);
      xe_pkt(8, dev.R_DEV, 8);
      wr(R_CMD, K_XFER_NEXT);
      xe_pkt(2, dev.R_DEV, 16);
      wr(R_CMD, K_XFER_NEXT);
      xe_done(X_OK, 20.0);
      chk(dev.ctl_stage == dev.CS_DONE, "the transfer completed on the bus");

      // Two transaction errors (CRC) in the data stage: retried, OK. String 1
      dev.inject_fault(dev.F_CRC, dev.T_IN, 0, 6, 3, dev.ST_DATA, 1, 2, 0);
      xe_start(32'h0301_0680, 32'h00FF_0409);
      xe_pkt(8, dev.R_STR1, 0);
      wr(R_CMD, K_XFER_NEXT);
      xe_pkt(6, dev.R_STR1, 8);
      wr(R_CMD, K_XFER_NEXT);
      xe_done(X_OK, 20.0);
      chk(dev.fr_hits[0] == 2,         "two corrupted data packets sent");
      status_chk(S_RUN, E_NONE, 4'd0);
      dev.clear_faults;

      // Three transaction errors (CRC) at the second data packet: ERROR, a
      // failure: BACKOFF, ERR CRC, STEP 0, ATTEMPT 1. The open transfer is
      // abandoned by the bus reset after BACKOFF (legal: doc "Attempts"):
      // the STATUS checker is off until RECOVERY.
      dev.chk_enable(dev.C_STATUS, 0);
      wr(R_IRQ_PEND, I_ALL);
      st_hist_clear;
      dev.inject_fault(dev.F_CRC, dev.T_IN, 0, 6, 3, dev.ST_DATA, 1, 3, 0);
      xe_start(32'h0302_0680, 32'h00FF_0409);
      xe_pkt(8, dev.R_STR2, 0);
      wr(R_CMD, K_XFER_NEXT);
      xe_done(X_ERROR, 20.0);
      chk(dev.fr_hits[0] == 3,         "three corrupted data packets sent");
      wait_state(S_BACKOFF, 2.0);
      status_chk(S_BACKOFF, E_CRC, 4'd0);
      rdv(R_STATUS, xe_v);
      chk(f_attempt(xe_v) == 2'd1,     "ATTEMPT 1 after the failed transfer");
      rdv(R_IRQ_PEND, xe_p);
      chk((xe_p & I_FAIL) != 0,        "FAIL on entry to BACKOFF");
      dev.clear_faults;
      xe_refused(1'b0);
      wait_state(S_RESET, 102.0);
      chk_range(st_dur_last(S_BACKOFF), T_BACKOFF, T_BACKOFF + T_MS + T_LAT, "BACKOFF length");
      wait_state(S_RECOVERY, 62.0);
      dev.chk_enable(dev.C_STATUS, 1);
      wait_state(S_RUN, 600.0);
      chk(!st_seen(S_DEBOUNCE),        "re-enumeration without a debounce");
      wait_ms(25.0);
      status_chk(S_RUN, E_NONE, 4'd0);
      rdv(R_STATUS, xe_v);
      chk(f_attempt(xe_v) == 2'd0,     "ATTEMPT cleared by the first answered poll");

      // Progress timeout: the device NAKs the data stage forever. The last
      // progress is the SETUP accepted; ERROR 500 to 501 ms later (the
      // IP sees the SETUP's ACK some 20 us after the model accepts it)
      dev.chk_enable(dev.C_STATUS, 0);
      wr(R_IRQ_PEND, I_ALL);
      st_hist_clear;
      dev.inject_fault(dev.F_NAK, dev.T_IN, 0, 6, 3, dev.ST_DATA, 0, -1, 0);
      xe_start(32'h0302_0680, 32'h00FF_0409);
      xe_done(X_ERROR, 520.0);
      chk_range(xe_t_ev - dev.st_xfer_start_t, 500.0 * T_MS, 501.0 * T_MS + T_LAT + 50.0e3, "progress timeout");
      chk(dev.fr_hits[0] >= 400,       "the data stage was retried every frame");
      wait_state(S_BACKOFF, 2.0);
      status_chk(S_BACKOFF, E_PROGRESS, 4'd0);
      rdv(R_STATUS, xe_v);
      chk(f_attempt(xe_v) == 2'd1,     "ATTEMPT 1 after the progress timeout");
      dev.clear_faults;
      // The bus reset after BACKOFF closes the open transfer (STATUS checker off)
      wait_state(S_RECOVERY, 200.0);
      dev.chk_enable(dev.C_STATUS, 1);
      stimulus_done = 1;
   end
