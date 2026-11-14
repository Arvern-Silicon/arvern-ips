//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ctrl_en_states2
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ctrl_en_states2.v
// Module Description : CTRL.EN = 0 in the later states: RUN (with a report
//                      in the window), BACKOFF, FAILED, UNSUPPORTED and
//                      FS_DETECTED. Each time: OFF, lines released and
//                      quiet, ERR / STEP / DEV_ID / DEV_IF / DEV_EP /
//                      REPORT_INFO / REPORT clear, the clock request low
//                      once OFF; EN = 1 again restarts from DETACHED
//                      (DEBOUNCE with the device attached, ATTEMPT 0).
//                      ctrl_en_states covers the early states.
//
// Doc "States", "Attempts", "Clock request", "Register map".
//----------------------------------------------------------------------------

reg [31:0] ce_v;
reg        ce_watch = 1'b0;
integer    ce_drv   = 0;                   // host drives while ce_watch

always @(posedge usb_oe)
  if (ce_watch) ce_drv = ce_drv + 1;

// A quiet bus point: after a keep-alive (a host drive shorter than 5 us),
// host and device both silent for 40 us. For the states with one short
// transaction per frame (RECOVERY, ENUM held by a NAK, RUN).
task c2_quiet;
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

// CTRL.EN = 0, the checks of OFF, then CTRL.EN = 1 again
task c2_off;
   input attached;                          // the device stays attached: EN = 1 leads on to DEBOUNCE
   begin
      wr(R_CTRL, CTRL_RST);
      // The doc gives no bound on reaching OFF; 20 us is a few bit times
      wait_state(S_OFF, 0.02);
      chk(usb_oe === 1'b0,             "lines released in OFF");
      status_chk(S_OFF, E_NONE, 4'd0);
      rd(R_DEV_ID,      32'h0);
      rd(R_DEV_IF,      32'h0);
      rd(R_DEV_EP,      32'h0);
      rd(R_REPORT_INFO, 32'h0);           // LEN 0: the window holds no report
      repeat (4) @(negedge free_clk);
      chk(pclk_en === 1'b0,            "no clock request once OFF with the bus idle");
      // OFF holds: nothing driven, no state change
      ce_drv   = 0;
      ce_watch = 1'b1;
      st_hist_clear;
      wait_ms(2.0);
      chk(tb_state == S_OFF && st_n == 0, "OFF holds while CTRL.EN = 0");
      chk(ce_drv == 0,                 "nothing driven in OFF");
      ce_watch = 1'b0;
      // EN = 1: DETACHED first
      wr(R_CTRL, CTRL_RST | C_EN);
      if (attached)
        begin
           wait_state(S_DEBOUNCE, 1.0);
           chk(st_hist[0] == S_DETACHED && st_hist[1] == S_DEBOUNCE, "EN = 1: OFF -> DETACHED -> DEBOUNCE");
           rdv(R_STATUS, ce_v);
           chk(f_attempt(ce_v) == 2'd0, "ATTEMPT = 0 in DEBOUNCE");
        end
      else
        begin
           wait_state(S_DETACHED, 1.0);
           wait_ms(1.0);
           chk(tb_state == S_DETACHED,  "EN = 1: OFF -> DETACHED");
        end
   end
endtask

initial
   begin
      wait_reset_done(5);
      wr(R_CTRL, CTRL_RST | C_EN);
      wait_state(S_DETACHED, 1.0);
      wait_ms(1.0);

      // RUN, a report in the window, the device information set
      dev.attach(dev.P_KBD);
      wait_state(S_RUN, 400.0);
      dev.push_report(8, 64'h0000_0004_0500_0002);
      expect_report(8'd0, 8, 64'h0000_0004_0500_0002, 30.0);
      rd(R_DEV_ID, 32'h0001_1209);
      rd(R_DEV_IF, {7'h0, 1'b1, 8'd1, 8'd1, 8'd0});
      rd(R_DEV_EP, {1'b0, 7'd8, 8'd10, 5'h00, 7'd8, 4'd1});
      wait_ms(5.0);
      c2_quiet(2.0);
      chk(tb_state == S_RUN,           "still RUN");
      c2_off(1'b1);

      // BACKOFF: the step-1 SETUP is never answered (three timeouts per
      // attempt); this run goes on to FAILED below
      dev.inject_fault(dev.F_SILENT, dev.T_SETUP, 0, 6, 1, dev.ST_SETUP, 0, -1, 0);
      wait_state(S_BACKOFF, 300.0);
      rdv(R_STATUS, ce_v);
      chk(f_err(ce_v) == E_TIMEOUT && f_step(ce_v) == 4'd1, "BACKOFF: ERR 1 at step 1");
      chk(f_attempt(ce_v) == 2'd1,     "BACKOFF: ATTEMPT 1");
      wait_ms(20.0);
      c2_off(1'b1);

      // FAILED: three failures from the fresh DEBOUNCE
      wait_state(S_FAILED, 700.0);
      chk(st_count(S_BACKOFF) == 2,    "two back-offs before FAILED");
      status_chk(S_FAILED, E_TIMEOUT, 4'd1);
      wait_ms(5.0);
      c2_off(1'b1);
      dev.clear_faults;

      // UNSUPPORTED: a hub
      dev.detach;
      wait_state(S_DETACHED, 1.0);
      dev.attach(dev.P_HUB);
      wait_state(S_UNSUPPORTED, 300.0);
      status_chk(S_UNSUPPORTED, E_HUB, 4'd1);
      wait_ms(5.0);
      c2_off(1'b1);

      // FS_DETECTED
      dev.detach;
      wait_state(S_DETACHED, 1.0);
      dev.attach(dev.P_FS);
      wait_state(S_FS_DETECTED, 110.0);
      rdv(R_STATUS, ce_v);
      chk(f_fs_dev(ce_v) == 1'b1,      "FS_DEV = 1 in FS_DETECTED");
      wait_ms(5.0);
      c2_off(1'b1);
      wait_state(S_FS_DETECTED, 110.0);
      chk_range(st_dur_last(S_DEBOUNCE), T_DEBOUNCE, T_DEBOUNCE + T_MS + T_LAT, "DEBOUNCE length after EN = 1");
      dev.detach;
      wait_state(S_DETACHED, 1.0);
      stimulus_done = 1;
   end
