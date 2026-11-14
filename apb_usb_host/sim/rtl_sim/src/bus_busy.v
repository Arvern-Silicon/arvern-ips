//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    bus_busy
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bus_busy.v
// Module Description : A device that babbles or holds the bus while polled
//                      (POLL_MS = 1). Throughout, every host drive other than
//                      the bus reset starts after at least 3 bit times of
//                      undriven J (checked here on the resolved lines).
//                      - Babble of 200 us after a report packet: a transient
//                        error, the report is delivered, no failure, no
//                        collision.
//                      - Device resume K for 1 ms in RUN: at most transient
//                        errors, no collision; the port stays in or comes
//                        back to RUN and polls again.
//                      - Bus held at K for 5 ms: the host never drives on
//                        it; the missed keep-alives and transactions fail
//                        the poll (BACKOFF, ERR 3 bus busy, STEP 0), then a
//                        bus reset and a new enumeration; the queued report
//                        is delivered.
//                      - Babble for 6 ms: the poll fails (a host packet
//                        started in a gap of the babble may collide)
//                        (BACKOFF, STEP 0), bus reset, new enumeration,
//                        report delivered.
//                      - Bus held at J for 3 ms: no host ACK during the
//                        hold; the port comes back to RUN and the report is
//                        delivered, never FAILED.
//
// Doc "Transactions" (Bus busy, Retry), "Bus timing", "Attempts". USB 2.0
// 8.7.4.
//----------------------------------------------------------------------------

reg        bb_j    = 1'b0;              // resolved lines at J, host released
real       bb_j_t  = 0.0;               // since
integer    bb_bad  = 0;                 // host starts without 3 bit times of idle
integer    bb_hs   = 0;                 // host handshakes decoded by the device
integer    bb_dhs  = 0;                 // device handshakes sent
integer    bb_h0, bb_a0, bb_r0, bb_c0;
real       bb_t0;
reg [31:0] bb_v;
reg [63:0] bb_d;
reg  [7:0] bb_seq;
reg  [6:0] bb_len;
reg [31:0] bb_ctrl;

// Doc "Bus busy": the host starts a packet or a keep-alive only after 4 bit
// samples of undriven J (at least 3 bit times); the bus reset is driven
// whatever the line state
always @(usb_dp or usb_dm or usb_oe)
  if (!usb_oe)
    begin
       if ((usb_dp === 1'b0) && (usb_dm === 1'b1))
         begin
            if (!bb_j)
              begin
                 bb_j   = 1'b1;
                 bb_j_t = $realtime;
              end
         end
       else
         bb_j = 1'b0;
    end

always @(posedge usb_oe)
  begin : bb_mon
     reg  jj;
     real jd;
     jj   = bb_j;
     jd   = $realtime - bb_j_t;
     bb_j = 1'b0;
     #1;                                    // STATE updates on the edge that drives
     if ((tb_rst_done === 1'b1) && (tb_state != S_RESET) && (!jj || (jd < 3.0 * T_BIT - 100.0)))
       begin
          bb_bad = bb_bad + 1;
          $display("ERROR: the host drives after %0.2f bit times of undriven J (%0s) %t ns",
                   jj ? jd / T_BIT : 0.0, jj ? "J" : "lines not at J", $time);
          error = error + 1;
       end
  end

always @(posedge dev.ev_tgl or negedge dev.ev_tgl)
  begin
     if (dev.last_ev == dev.LE_HHS)    bb_hs  = bb_hs + 1;
     if (dev.last_ev == dev.LE_DEV_HS) bb_dhs = bb_dhs + 1;
  end

// Keep-alive gap checker: the doc requires the host to skip a keep-alive due
// on a busy bus, so a busy window longer than a frame is a legal gap
task bb_ka_quiet;
   input en;
   dev.chk_enable(dev.C_KEEPALIVE, !en);
endtask

// A device-driven J is electrically the idle bus, so a host following the
// idle rule starts over it and collides; the model does not see host
// packets sent while it drives, and may see the tail of one when it
// releases. Allowed in the J-hold and long-babble windows only: collisions, and the checkers
// that decode host packets.
task bb_drive_quiet;
   input en;
   begin
      tb_coll_ok = en;
      dev.chk_enable(dev.C_COLL,      !en);
      dev.chk_enable(dev.C_KEEPALIVE, !en);
      dev.chk_enable(dev.C_IDLE,      !en);
      dev.chk_enable(dev.C_PID,       !en);
      dev.chk_enable(dev.C_CRC,       !en);
      dev.chk_enable(dev.C_STUFF,     !en);
      dev.chk_enable(dev.C_EOP,       !en);
      dev.chk_enable(dev.C_PROTO,     !en);
      dev.chk_enable(dev.C_TIMEOUT,   !en);
      dev.chk_enable(dev.C_IPD,       !en);
   end
endtask

// Wait until the device has acknowledged-sent the queued report (at most ms),
// 200 us, then the window holds it
task bb_delivered;
   input [63:0] d;
   input   real ms;
   begin
      bb_t0 = $realtime;
      while ((dev.int_ack_cnt == bb_a0) && ($realtime - bb_t0 < ms * T_MS)) #(10.0e3);
      chk(dev.int_ack_cnt == bb_a0 + 1, "the queued report is acknowledged once");
      #(200.0e3);
      chk(tb_state == S_RUN, "RUN when the report is delivered");
      read_report(bb_len, bb_seq, bb_d);
      chk(bb_len == 7'd8, "REPORT_INFO.LEN of the queued report");
      chk32(bb_d[31:0],  d[31:0],  "REPORT[0] of the queued report");
      chk32(bb_d[63:32], d[63:32], "REPORT[1] of the queued report");
   end
endtask

// A busy window that fails the poll: BACKOFF with STEP 0 and ATTEMPT 1
task bb_fail_chk;
   input [3:0] er;                          // expected ERR, 4'hF: CRC or bus-busy class
   begin
      wait_state(S_BACKOFF, 20.0);
      rdv(R_STATUS, bb_v);
      chk(f_state(bb_v) == S_BACKOFF, "busy bus: the poll fails");
      if (er != 4'hF)
        chk(f_err(bb_v) == er, "busy bus: STATUS.ERR");
      else
        chk((f_err(bb_v) == E_CRC) || (f_err(bb_v) == E_UNEXPECTED), "babble: STATUS.ERR 2 or 3");
      chk(f_step(bb_v) == 4'd0,    "busy bus: STEP 0");
      chk(f_attempt(bb_v) == 2'd1, "busy bus: ATTEMPT 1");
      irq_chk(I_FAIL, I_FAIL);
      if (DIAG_EN != 0)
        begin
           rdv(R_DIAG0, bb_v);
           chk(bb_v[7:0] + bb_v[15:8] + bb_v[23:16] >= 3, "three transaction errors counted");
           if (er == E_UNEXPECTED)
             chk(bb_v[23:16] >= 1, "bus-busy errors counted in DIAG0[23:16]");
        end
   end
endtask

// The device drive in progress ends, then 2 ms
task bb_drive_end;
   begin
      wait (dev.drv_en === 1'b0);
      wait_ms(2.0);
   end
endtask

// After the failure: BACKOFF ends in a bus reset, then the new enumeration
task bb_recover;
   begin
      wait_state(S_RESET, 102.0);
      chk(st_seen(S_BACKOFF), "the bus reset follows the back-off");
      wait_state(S_RUN, 400.0);
   end
endtask

initial
   begin
      wait_reset_done(5);
      bb_ctrl = C_EN | C_BOOT | C_IDLE0 | (32'd1 << 8);
      enumerate(dev.P_KBD, bb_ctrl, 600.0);
      wait_ms(5.0);

      // Short babble after a report packet: transient
      st_hist_clear;
      if (DIAG_EN != 0) wr(R_DIAG0, 32'h0);
      bb_a0 = dev.int_ack_cnt;
      bb_h0 = bb_hs;
      bb_ka_quiet(1);
      dev.push_report(8, 64'h0102_0304_0506_0708);
      dev.inject_fault(dev.F_BABBLE, dev.T_IN, 1, -1, -1, -1, 0, 1, 200);
      bb_delivered(64'h0102_0304_0506_0708, 30.0);
      chk(bb_hs == bb_h0 + 1, "babble is not acknowledged");
      chk(!st_seen(S_BACKOFF), "short babble: no failure");
      if (DIAG_EN != 0)
        begin
           rdv(R_DIAG0, bb_v);
           chk(bb_v[23:0] != 24'h0, "the babble counts as a transaction error");
        end
      wait_ms(3.0);
      bb_ka_quiet(0);
      dev.clear_faults;

      // Device resume K for 1 ms, mid-frame after a poll
      st_hist_clear;
      bb_r0 = bb_dhs;
      bb_t0 = $realtime;
      while ((bb_dhs == bb_r0) && ($realtime - bb_t0 < 10.0 * T_MS)) #(10.0e3);
      chk(bb_dhs != bb_r0, "a poll answered NAK before the resume");
      #(300.0e3);
      bb_ka_quiet(1);
      dev.drive_resume(1);
      bb_a0 = dev.int_ack_cnt;
      dev.push_report(8, 64'h1020_3040_5060_7080);
      bb_delivered(64'h1020_3040_5060_7080, 400.0);
      chk(!st_seen(S_FAILED), "resume K: never FAILED");
      wait_ms(3.0);
      bb_ka_quiet(0);

      // Bus held at K for 5 ms: no host drive on it, the poll fails
      st_hist_clear;
      if (DIAG_EN != 0) wr(R_DIAG0, 32'h0);
      wr(R_IRQ_PEND, I_ALL);
      bb_a0 = dev.int_ack_cnt;
      bb_ka_quiet(1);
      dev.push_report(8, 64'hCAFE_0000_1111_2222);
      dev.inject_fault(dev.F_HOLD_K, dev.T_IN, 1, -1, -1, -1, 0, 1, 5);
      bb_fail_chk(E_UNEXPECTED);
      bb_drive_end;
      bb_ka_quiet(0);
      bb_recover;
      bb_delivered(64'hCAFE_0000_1111_2222, 40.0);
      dev.clear_faults;

      // Babble for 6 ms: the poll fails
      st_hist_clear;
      if (DIAG_EN != 0) wr(R_DIAG0, 32'h0);
      wr(R_IRQ_PEND, I_ALL);
      bb_a0 = dev.int_ack_cnt;
      // Random babble has gaps of 4 idle bits: a host packet started in one
      // collides when the babble resumes (doc "Bus busy"), a legal outcome
      bb_drive_quiet(1);
      dev.push_report(8, 64'hBEEF_3333_4444_5555);
      dev.inject_fault(dev.F_BABBLE, dev.T_IN, 1, -1, -1, -1, 0, 1, 6000);
      bb_fail_chk(4'hF);
      bb_drive_end;
      bb_drive_quiet(0);
      bb_recover;
      bb_delivered(64'hBEEF_3333_4444_5555, 40.0);
      dev.clear_faults;

      // Bus held at J for 3 ms: the port recovers, never FAILED
      st_hist_clear;
      bb_a0 = dev.int_ack_cnt;
      bb_c0 = tb_coll_n;
      bb_r0 = dev.st_faults;
      bb_h0 = bb_hs;
      bb_drive_quiet(1);
      dev.push_report(8, 64'hD00D_6666_7777_8888);
      dev.inject_fault(dev.F_HOLD_J, dev.T_IN, 1, -1, -1, -1, 0, 1, 3);
      bb_t0 = $realtime;
      while ((dev.st_faults == bb_r0) && ($realtime - bb_t0 < 10.0 * T_MS)) #(10.0e3);
      chk(dev.st_faults == bb_r0 + 1, "the J hold was applied");
      wait (dev.drv_en === 1'b1);
      wait (dev.drv_en === 1'b0);
      chk(bb_hs == bb_h0, "no host ACK during the J hold");
      bb_drive_end;
      bb_drive_quiet(0);
      bb_delivered(64'hD00D_6666_7777_8888, 400.0);
      chk(!st_seen(S_FAILED), "J hold: never FAILED");
      $display("[%0t] collisions during the J hold: %0d", $time, tb_coll_n - bb_c0);
      dev.clear_faults;

      wait_ms(5.0);
      chk(bb_bad == 0, "no host start on a busy bus");
      status_chk(S_RUN, E_NONE, 4'd0);
      stimulus_done = 1;
   end
