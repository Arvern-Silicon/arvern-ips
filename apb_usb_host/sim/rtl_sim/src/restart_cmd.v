//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    restart_cmd
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : restart_cmd.v
// Module Description : CMD.RESTART is ignored in OFF, DETACHED, DEBOUNCE and
//                      RESET (no state change, the 100 ms debounce and the
//                      60 ms reset run their full length); in RECOVERY
//                      (with ATTEMPT 1 after a failure), RUN and UNSUPPORTED
//                      it leads to RESET with ATTEMPT / ERR / STEP clear,
//                      without a new debounce, and the device is enumerated
//                      again. restart_cmd2 covers ENUM, BACKOFF and FAILED.
//
// Doc "States", "Attempts", "Bus timing", "Register map".
//----------------------------------------------------------------------------

reg [31:0] rs_v;
reg        rs_watch = 1'b0;
integer    rs_drv   = 0;                   // host drives while rs_watch

always @(posedge usb_oe)
  if (rs_watch) rs_drv = rs_drv + 1;

// A quiet bus point: after a keep-alive (a host drive shorter than 5 us),
// host and device both silent for 40 us. For the states with one short
// transaction per frame (RECOVERY, ENUM held by a NAK, RUN).
task rs_quiet;
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

// CMD.RESTART where the doc sends it to RESET: RESET reached with ATTEMPT,
// ERR and STEP clear, then a full 60 ms bus reset
task rs_restart;
   begin
      st_hist_clear;
      wr(R_CMD, K_RESTART);
      // The doc gives no bound; the restart is taken within a frame
      wait_state(S_RESET, 2.0);
      rdv(R_STATUS, rs_v);
      chk(f_state(rs_v) == S_RESET,    "RESTART leads to RESET");
      chk(f_attempt(rs_v) == 2'd0,     "RESTART clears ATTEMPT");
      chk(f_err(rs_v) == E_NONE && f_step(rs_v) == 4'd0, "RESTART clears ERR / STEP");
      rd(R_REPORT_INFO, 32'h0);
      wait_state(S_RECOVERY, 62.0);
      chk_range(st_dur_last(S_RESET), T_RESET, T_RESET + T_MS + T_LAT, "RESET length after RESTART");
      chk(st_hist[0] == S_RESET,       "RESET is the first state after the RESTART");
   end
endtask

initial
   begin
      wait_reset_done(5);

      // OFF
      st_hist_clear;
      rs_watch = 1'b1;
      wr(R_CMD, K_RESTART);
      wait_ms(1.0);
      chk(tb_state == S_OFF && st_n == 0, "RESTART ignored in OFF");
      chk(rs_drv == 0,                 "nothing driven after RESTART in OFF");

      // DETACHED
      wr(R_CTRL, CTRL_RST | C_EN);
      wait_state(S_DETACHED, 1.0);
      wait_ms(1.0);
      st_hist_clear;
      wr(R_CMD, K_RESTART);
      wait_ms(2.0);
      chk(tb_state == S_DETACHED && st_n == 0, "RESTART ignored in DETACHED");
      chk(rs_drv == 0,                 "nothing driven after RESTART in DETACHED");
      rs_watch = 1'b0;

      // DEBOUNCE. The step-1 SETUP goes unanswered three times: the first
      // enumeration fails once (ERR 1, ATTEMPT 1)
      dev.inject_fault(dev.F_SILENT, dev.T_SETUP, 0, 6, 1, dev.ST_SETUP, 0, 3, 0);
      st_hist_clear;
      dev.attach(dev.P_KBD);
      wait_state(S_DEBOUNCE, 1.0);
      wait_ms(30.0);
      wr(R_CMD, K_RESTART);
      wait_state(S_RESET, 75.0);
      chk_range(st_dur_last(S_DEBOUNCE), T_DEBOUNCE, T_DEBOUNCE + T_MS + T_LAT, "DEBOUNCE length with a RESTART in it");
      chk(st_n == 2 && st_hist[0] == S_DEBOUNCE, "RESTART ignored in DEBOUNCE");

      // RESET
      wait_ms(30.0);
      wr(R_CMD, K_RESTART);
      wait_state(S_RECOVERY, 35.0);
      chk_range(st_dur_last(S_RESET), T_RESET, T_RESET + T_MS + T_LAT, "RESET length with a RESTART in it");
      chk(st_count(S_RESET) == 1,      "RESTART ignored in RESET");

      // The failure, the back-off and the next RECOVERY with ATTEMPT 1
      wait_state(S_BACKOFF, 50.0);
      status_chk(S_BACKOFF, E_TIMEOUT, 4'd1);
      wait_state(S_RECOVERY, 200.0);
      wait_ms(2.0);
      rs_quiet(2.0);
      rdv(R_STATUS, rs_v);
      chk(f_state(rs_v) == S_RECOVERY && f_attempt(rs_v) == 2'd1, "RECOVERY after a back-off, ATTEMPT 1");
      chk(f_err(rs_v) == E_TIMEOUT && f_step(rs_v) == 4'd1, "ERR / STEP of the failure kept");

      // RECOVERY
      rs_restart;
      wait_state(S_RUN, 300.0);
      chk(!st_seen(S_DEBOUNCE),        "no new debounce after RESTART");
      status_chk(S_RUN, E_NONE, 4'd0);
      rd(R_DEV_ID, 32'h0001_1209);
      dev.push_report(8, 64'h0000_0004_0000_0001);
      expect_report(8'd0, 8, 64'h0000_0004_0000_0001, 30.0);

      // RUN: enumerated again, the report state cleared on leaving RUN
      wait_ms(5.0);
      rs_quiet(2.0);
      wr(R_IRQ_PEND, I_ALL);
      rs_restart;
      wait_state(S_RUN, 300.0);
      chk(!st_seen(S_DEBOUNCE),        "no new debounce after RESTART");
      chk(st_count(S_ENUM) >= 1,       "the device is enumerated again");
      irq_chk(I_READY, I_READY | I_FAIL | I_DETACH);
      dev.push_report(8, 64'h0000_0005_0000_0001);
      expect_report(8'd0, 8, 64'h0000_0005_0000_0001, 30.0);

      // UNSUPPORTED: a hub
      wait_ms(5.0);
      rs_quiet(2.0);
      dev.detach;
      wait_state(S_DETACHED, 0.05);
      dev.attach(dev.P_HUB);
      wait_state(S_UNSUPPORTED, 300.0);
      status_chk(S_UNSUPPORTED, E_HUB, 4'd1);
      wait_ms(5.0);
      // The doc does not say whether step 1's status stage completes before
      // the hub verdict; the restart's bus reset would close it
      dev.chk_enable(dev.C_STATUS, 0);
      rs_restart;
      dev.chk_enable(dev.C_STATUS, 1);
      wait_state(S_UNSUPPORTED, 100.0);
      chk(st_count(S_ENUM) == 1 && !st_seen(S_DEBOUNCE), "the hub is enumerated again after RESTART");
      status_chk(S_UNSUPPORTED, E_HUB, 4'd1);
      wait_ms(1.0);
      dev.detach;
      wait_state(S_DETACHED, 0.05);
      stimulus_done = 1;
   end
