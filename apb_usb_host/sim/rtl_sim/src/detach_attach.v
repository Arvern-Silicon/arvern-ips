//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    detach_attach
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : detach_attach.v
// Module Description : Disconnects. In RUN: DETACHED after an SE0 of more
//                      than 2.25 us, IRQ_PEND.DETACH, REPORT_INFO
//                      cleared, the host's own SE0 (bus resets,
//                      EOPs) never taken for a disconnect. In RECOVERY and
//                      ENUM: DETACHED without DETACH. During RESET: not seen
//                      while the host drives, detected in RECOVERY without
//                      a host drive. In BACKOFF: ERR / STEP survive DETACHED
//                      and DEBOUNCE, cleared on entry to RUN.
//                      detach_attach2 repeats detach / attach cycles.
//
// Doc "States", "Line state, attachment and disconnect", "Attempts",
// "Register map".
//----------------------------------------------------------------------------

reg [31:0] da_v;
real       da_t;
reg        da_watch = 1'b0;
integer    da_drv   = 0;                   // host drives while da_watch

always @(posedge usb_oe)
  if (da_watch) da_drv = da_drv + 1;

// A quiet bus point: after a keep-alive (a host drive shorter than 5 us),
// host and device both silent for 40 us. For the states with one short
// transaction per frame (RECOVERY, ENUM held by a NAK, RUN).
task da_quiet;
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

// Disconnect at a quiet point with the host released: DETACHED once the SE0
// has lasted more than 2.25 us (TDDIS 2 to 2.5 us; 4 pclk of synchroniser
// and register latency allowed)
task da_detach_quiet;
   real t0;
   begin
      da_quiet(2.0);
      dev.detach;
      t0 = $realtime;
      wait_state(S_DETACHED, 0.05);
      chk_range($realtime - t0, 2250.0, 2500.0 + 4.0 * PCLK_P, "disconnect detection (SE0 > 2.25 us)");
   end
endtask

initial
   begin
      wait_reset_done(5);
      wr(R_CTRL, CTRL_RST | C_EN);
      wait_state(S_DETACHED, 1.0);
      wait_ms(1.0);

      // RUN. The bus resets and every EOP are host SE0: no disconnect
      st_hist_clear;
      dev.attach(dev.P_KBD);
      wait_state(S_RUN, 400.0);
      chk(st_count(S_DETACHED) == 0,   "the host's own SE0 is not a disconnect");
      dev.push_report(8, 64'h0000_0004_0500_0002);
      expect_report(8'd0, 8, 64'h0000_0004_0500_0002, 30.0);
      wait_ms(20.0);
      chk(tb_state == S_RUN && st_count(S_DETACHED) == 0, "RUN holds with keep-alives and polls");
      wr(R_IRQ_PEND, I_ALL);
      da_detach_quiet;
      irq_chk(I_DETACH | I_STATE, I_DETACH | I_STATE | I_FAIL | I_READY | I_REPORT);
      status_chk(S_DETACHED, E_NONE, 4'd0);
      rd(R_REPORT_INFO, 32'h0);           // LEN 0: the window holds no report
      wait_ms(5.0);
      chk(tb_state == S_DETACHED,      "DETACHED holds with nothing attached");

      // RECOVERY
      wr(R_IRQ_PEND, I_ALL);
      dev.attach(-1);
      wait_state(S_RECOVERY, 200.0);
      wait_ms(3.0);
      da_detach_quiet;
      irq_chk(I_STATE, I_DETACH | I_STATE);
      wait_ms(2.0);

      // ENUM, held at step 1 by a NAKed data stage
      dev.inject_fault(dev.F_NAK, dev.T_IN, 0, 6, 1, dev.ST_DATA, 0, -1, 0);
      wr(R_IRQ_PEND, I_ALL);
      dev.attach(-1);
      wait_state(S_ENUM, 200.0);
      wait_ms(5.0);
      chk(tb_state == S_ENUM,          "ENUM held at step 1");
      da_detach_quiet;
      irq_chk(I_STATE, I_DETACH | I_STATE);
      dev.clear_faults;
      wait_ms(2.0);

      // RESET: the lines are driven and the detach cannot be seen; the host
      // keeps the reset SE0 on the empty port, which the model's DETACHED
      // checker would count, until RECOVERY detects the disconnect
      wr(R_IRQ_PEND, I_ALL);
      st_hist_clear;
      dev.attach(-1);
      wait_state(S_RESET, 102.0);
      wait_ms(10.0);
      dev.chk_enable(dev.C_DETACHED, 0);
      dev.detach;
      wait_ms(1.0);
      chk(tb_state == S_RESET,         "a detach is not seen during RESET");
      wait_state(S_RECOVERY, 55.0);
      da_t     = $realtime;
      da_drv   = 0;
      da_watch = 1'b1;
      wait_state(S_DETACHED, 0.05);
      chk($realtime - da_t < 20.0e3, "disconnect detected early in RECOVERY");
      chk(!st_seen(S_ENUM),            "RECOVERY -> DETACHED, no ENUM");
      wait_ms(1.0);
      chk(da_drv == 0,                 "no host drive after the reset on the empty port");
      da_watch = 1'b0;
      dev.chk_enable(dev.C_DETACHED, 1);
      irq_chk(I_STATE, I_DETACH | I_STATE);

      // BACKOFF after a failure at step 1: ERR / STEP survive DETACHED
      dev.inject_fault(dev.F_SILENT, dev.T_SETUP, 0, 6, 1, dev.ST_SETUP, 0, 3, 0);
      wr(R_IRQ_PEND, I_ALL);
      dev.attach(-1);
      wait_state(S_BACKOFF, 300.0);
      status_chk(S_BACKOFF, E_TIMEOUT, 4'd1);
      irq_chk(I_FAIL, I_FAIL | I_DETACH);
      wait_ms(20.0);
      dev.detach;
      wait_state(S_DETACHED, 0.05);
      status_chk(S_DETACHED, E_TIMEOUT, 4'd1);
      irq_chk(I_STATE, I_DETACH | I_STATE);
      wait_ms(5.0);
      dev.clear_faults;
      // Kept through DEBOUNCE (ATTEMPT cleared there), cleared on entry to RUN
      dev.attach(-1);
      wait_state(S_DEBOUNCE, 1.0);
      wait_ms(1.0);
      rdv(R_STATUS, da_v);
      chk(f_err(da_v) == E_TIMEOUT && f_step(da_v) == 4'd1, "ERR / STEP kept in DEBOUNCE");
      chk(f_attempt(da_v) == 2'd0,     "ATTEMPT cleared on entry to DEBOUNCE");
      wait_state(S_RUN, 400.0);
      status_chk(S_RUN, E_NONE, 4'd0);
      dev.push_report(8, 64'h0000_0004_0500_0003);
      expect_report(8'd0, 8, 64'h0000_0004_0500_0003, 30.0);
      wait_ms(5.0);
      da_detach_quiet;
      stimulus_done = 1;
   end
