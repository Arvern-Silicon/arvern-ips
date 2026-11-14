//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    restart_cmd2
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : restart_cmd2.v
// Module Description : CMD.RESTART in ENUM (held at step 1 by a NAK, ATTEMPT
//                      1 after a failure), BACKOFF and FAILED: RESET with
//                      ATTEMPT / ERR / STEP clear, no new debounce, the
//                      device enumerated again and delivering a report.
//                      restart_cmd covers the other states.
//
// Doc "States", "Attempts", "Bus timing", "Register map".
//----------------------------------------------------------------------------

reg [31:0] rs_v;

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


// Back in RUN after a RESTART, without a debounce, delivering a report
task rs_back_in_run;
   input [63:0] rpt;
   begin
      wait_state(S_RUN, 300.0);
      chk(!st_seen(S_DEBOUNCE),        "no new debounce after RESTART");
      status_chk(S_RUN, E_NONE, 4'd0);
      rd(R_DEV_ID, 32'h0001_1209);
      dev.push_report(8, rpt);
      expect_report(8'd0, 8, rpt, 30.0);
   end
endtask

initial
   begin
      wait_reset_done(5);
      wr(R_CTRL, CTRL_RST | C_EN);
      wait_state(S_DETACHED, 1.0);
      wait_ms(1.0);

      // ENUM with ATTEMPT 1: the first step-1 SETUP goes unanswered three
      // times (one failure), then the data stage is NAKed forever
      dev.inject_fault(dev.F_SILENT, dev.T_SETUP, 0, 6, 1, dev.ST_SETUP, 0, 3, 0);
      dev.inject_fault(dev.F_NAK, dev.T_IN, 0, 6, 1, dev.ST_DATA, 0, -1, 0);
      dev.attach(dev.P_KBD);
      wait_state(S_BACKOFF, 300.0);
      wait_state(S_ENUM, 200.0);
      wait_ms(5.0);
      rs_quiet(2.0);
      rdv(R_STATUS, rs_v);
      chk(f_state(rs_v) == S_ENUM && f_attempt(rs_v) == 2'd1, "ENUM after a back-off, ATTEMPT 1");
      chk(f_err(rs_v) == E_TIMEOUT && f_step(rs_v) == 4'd1, "ERR / STEP of the failure kept");
      // The restart's bus reset abandons the open GET_DESCRIPTOR
      dev.chk_enable(dev.C_STATUS, 0);
      rs_restart;
      dev.chk_enable(dev.C_STATUS, 1);
      dev.clear_faults;
      rs_back_in_run(64'h0000_0004_0000_0101);

      // BACKOFF: one more silent step 1 after a RESTART from RUN
      dev.inject_fault(dev.F_SILENT, dev.T_SETUP, 0, 6, 1, dev.ST_SETUP, 0, 3, 0);
      wait_ms(5.0);
      rs_quiet(2.0);
      rs_restart;
      wait_state(S_BACKOFF, 50.0);
      rdv(R_STATUS, rs_v);
      chk(f_attempt(rs_v) == 2'd1,     "BACKOFF: ATTEMPT 1");
      chk(f_err(rs_v) == E_TIMEOUT && f_step(rs_v) == 4'd1, "BACKOFF: ERR 1 at step 1");
      wait_ms(20.0);
      rs_restart;
      rs_back_in_run(64'h0000_0004_0000_0202);

      // FAILED: step 1 never answered from a RESTART in RUN
      dev.inject_fault(dev.F_SILENT, dev.T_SETUP, 0, 6, 1, dev.ST_SETUP, 0, -1, 0);
      wait_ms(5.0);
      rs_quiet(2.0);
      rs_restart;
      wait_state(S_FAILED, 600.0);
      chk(st_count(S_BACKOFF) == 2,    "two back-offs before FAILED");
      rdv(R_STATUS, rs_v);
      chk(f_attempt(rs_v) != 2'd0,     "FAILED: ATTEMPT not 0");
      chk(f_err(rs_v) == E_TIMEOUT && f_step(rs_v) == 4'd1, "FAILED: ERR 1 at step 1");
      wait_ms(5.0);
      dev.clear_faults;
      rs_restart;
      rs_back_in_run(64'h0000_0004_0000_0303);
      stimulus_done = 1;
   end
