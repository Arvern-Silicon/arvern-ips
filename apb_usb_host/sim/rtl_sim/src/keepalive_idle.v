//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    keepalive_idle
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : keepalive_idle.v
// Module Description : A keyboard with nothing to report answers every poll
//                      with NAK. The port enters RUN with ATTEMPT 1 (one
//                      failed step-1 attempt), the first answered poll
//                      clears it; the port then stays in RUN for 300 ms
//                      (bInterval polling) and 50 ms more polling every
//                      frame (POLL_MS = 1): no state change, no FAIL, no
//                      report, ERR 0, and the device never suspends (the
//                      model's KEEPALIVE checker watches every 1 ms frame).
//                      A report pushed afterwards is delivered.
//
// Doc "Attempts", "Polling", "Transactions" (NAK), "Bus timing" (keep-alive).
//----------------------------------------------------------------------------

reg [31:0] ki_v;
reg        ki_watch = 1'b0;
integer    ki_susp  = 0;                   // device suspends while ki_watch

always @(posedge dev_suspended)
  if (ki_watch) ki_susp = ki_susp + 1;

// RUN held: no state change since the last st_hist_clear, nothing reported
task ki_run_chk;
   begin
      chk(tb_state == S_RUN && st_n == 0, "RUN holds with a device answering NAK");
      rdv(R_STATUS, ki_v);
      chk(f_attempt(ki_v) == 2'd0,     "ATTEMPT 0 while polls are answered");
      chk(f_err(ki_v) == E_NONE && f_step(ki_v) == 4'd0, "no ERR / STEP");
      irq_chk(32'h0, I_FAIL | I_REPORT | I_DETACH | I_STATE);
      rd(R_REPORT_INFO, 32'h0);
      chk(ki_susp == 0 && dev_suspended === 1'b0, "the device never suspends in RUN");
   end
endtask

initial
   begin
      wait_reset_done(5);
      wr(R_CTRL, CTRL_RST | C_EN);
      wait_state(S_DETACHED, 1.0);
      wait_ms(1.0);

      // One failure at step 1, so that RUN starts with ATTEMPT 1
      dev.inject_fault(dev.F_SILENT, dev.T_SETUP, 0, 6, 1, dev.ST_SETUP, 0, 3, 0);
      dev.attach(dev.P_KBD);
      wait_state(S_BACKOFF, 300.0);
      wait_state(S_RECOVERY, 200.0);
      wait_ms(2.0);
      rdv(R_STATUS, ki_v);
      chk(f_attempt(ki_v) == 2'd1,     "ATTEMPT 1 after the failure");
      wait_state(S_RUN, 300.0);
      ki_watch = 1'b1;

      // bInterval (10 ms) polling: the first poll is answered within 20 ms
      wait_ms(20.0);
      st_hist_clear;
      wr(R_IRQ_PEND, I_ALL);
      rdv(R_STATUS, ki_v);
      chk(f_state(ki_v) == S_RUN && f_attempt(ki_v) == 2'd0, "the first answered poll clears ATTEMPT");
      wait_ms(300.0);
      ki_run_chk;

      // Every frame
      wr(R_CTRL, CTRL_RST | C_EN | (32'd1 << 8));
      wait_ms(50.0);
      ki_run_chk;

      // A report after all of this
      dev.push_report(8, 64'h0000_0004_0000_0002);
      expect_report(8'd0, 8, 64'h0000_0004_0000_0002, 10.0);
      chk(tb_state == S_RUN,           "still RUN");
      chk(ki_susp == 0,                "the device never suspended");
      ki_watch = 1'b0;
      stimulus_done = 1;
   end
