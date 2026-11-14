//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    poll_dead_device
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : poll_dead_device.v
// Module Description : A device that stops answering while it is polled.
//                      1) Silent on every IN to its interrupt endpoint: the
//                         poll fails (ERR 1, STEP 0), the device enumerates
//                         again, fails its first poll again (ATTEMPT 2) and
//                         the third failure enters FAILED; the port stays
//                         released there; a detach leads to DETACHED with
//                         ERR / STEP kept and no DETACH interrupt.
//                      2) Silent on every token: the poll fails, then the
//                         re-enumerations fail at step 1 (ERR 1, STEP 1) and
//                         the third failure enters FAILED.
//
// Doc "Attempts", "Polling", "Enumeration", "States", "Register map".
//----------------------------------------------------------------------------

reg [31:0] pd_v;
integer    pd_oe = 0;                   // host drive starts

always @(posedge usb_oe) pd_oe = pd_oe + 1;

// In state st: check ERR, STEP and ATTEMPT
task pd_status;
   input  [3:0] st;
   input  [3:0] er;
   input  [3:0] sp;
   input  [1:0] at;
   begin
      rdv(R_STATUS, pd_v);
      if ((f_state(pd_v) != st) || (f_err(pd_v) != er) || (f_step(pd_v) != sp) || (f_attempt(pd_v) != at))
        begin
           $display("ERROR: STATUS 0x%h: STATE %0s ERR %0d STEP %0d ATTEMPT %0d, expected %0s %0d %0d %0d %t ns",
                    pd_v, st_name(f_state(pd_v)), f_err(pd_v), f_step(pd_v), f_attempt(pd_v),
                    st_name(st), er, sp, at, $time);
           error = error + 1;
        end
   end
endtask

// FAILED holds with the lines released, then a detach leads to DETACHED
task pd_failed_then_detach;
   input  [3:0] er;
   input  [3:0] sp;
   integer      n0;
   begin
      rdv(R_STATUS, pd_v);
      chk(f_state(pd_v) == S_FAILED, "third failure: FAILED");
      chk(f_err(pd_v) == er,         "FAILED: ERR of the last failure");
      chk(f_step(pd_v) == sp,        "FAILED: STEP of the last failure");
      irq_chk(I_FAIL, I_FAIL);
      n0 = pd_oe;
      wait_ms(20.0);
      chk(tb_state == S_FAILED, "FAILED waits for a disconnect");
      chk((pd_oe == n0) && (usb_oe === 1'b0), "FAILED: the lines stay released");
      wr(R_IRQ_PEND, I_ALL);
      dev.detach;
      wait_state(S_DETACHED, 5.0);
      rdv(R_STATUS, pd_v);
      chk(f_err(pd_v) == er,  "DETACHED keeps ERR");
      chk(f_step(pd_v) == sp, "DETACHED keeps STEP");
      rdv(R_IRQ_PEND, pd_v);
      chk(pd_v[2] == 1'b0, "no IRQ_PEND.DETACH for a disconnect outside RUN");
   end
endtask

initial
   begin
      wait_reset_done(5);
      wr(R_IRQ_EN, 32'h0);

      // 1) Silent interrupt endpoint
      enumerate(dev.P_KBD, C_EN | C_BOOT | C_IDLE0, 600.0);
      wait_ms(30.0);
      pd_status(S_RUN, E_NONE, 4'd0, 2'd0);
      st_hist_clear;
      dev.inject_fault(dev.F_SILENT, dev.T_IN, 1, -1, -1, -1, 0, -1, 0);

      wait_state(S_BACKOFF, 60.0);
      pd_status(S_BACKOFF, E_TIMEOUT, 4'd0, 2'd1);
      wait_state(S_RUN, 400.0);
      wait_state(S_BACKOFF, 60.0);
      pd_status(S_BACKOFF, E_TIMEOUT, 4'd0, 2'd2);
      wait_state(S_RUN, 400.0);
      wait_state(S_FAILED, 60.0);
      chk(st_count(S_BACKOFF) == 2, "two back-offs before FAILED");
      chk(st_count(S_RUN) == 2,     "enumerated again after each back-off");
      chk(!st_seen(S_DEBOUNCE),     "no debounce between the attempts");
      pd_failed_then_detach(E_TIMEOUT, 4'd0);

      // 2) Silent on every token once polled
      dev.clear_faults;
      wait_ms(2.0);
      dev.attach(dev.P_KBD);
      wait_state(S_DEBOUNCE, 2.0);
      rdv(R_STATUS, pd_v);
      chk(f_attempt(pd_v) == 2'd0, "DEBOUNCE clears ATTEMPT");
      wait_state(S_RUN, 600.0);
      wait_ms(30.0);
      pd_status(S_RUN, E_NONE, 4'd0, 2'd0);
      st_hist_clear;
      dev.inject_fault(dev.F_SILENT, dev.T_ANY, -1, -1, -1, -1, 0, -1, 0);

      wait_state(S_BACKOFF, 60.0);
      pd_status(S_BACKOFF, E_TIMEOUT, 4'd0, 2'd1);
      wait_state(S_ENUM, 200.0);
      wait_state(S_BACKOFF, 60.0);
      pd_status(S_BACKOFF, E_TIMEOUT, 4'd1, 2'd2);
      wait_state(S_FAILED, 300.0);
      chk(!st_seen(S_RUN),          "no enumeration completes");
      chk(st_count(S_BACKOFF) == 2, "two back-offs before FAILED");
      pd_failed_then_detach(E_TIMEOUT, 4'd1);
      dev.clear_faults;
      stimulus_done = 1;
   end
