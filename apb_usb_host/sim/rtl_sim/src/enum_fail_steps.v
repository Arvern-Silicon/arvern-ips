//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    enum_fail_steps
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : enum_fail_steps.v
// Module Description : A failure at enumeration steps 1, 3, 4 and 5: a STALL
//                      of the step-1 data stage, three silent SET_ADDRESS
//                      status stages, three CRC errors on the first step-4
//                      data packet, three overlong step-1 data packets, a
//                      STALL of the step-5 data stage. Each one: BACKOFF with
//                      STATUS.ERR / STEP of the cause, ATTEMPT 1, IRQ_PEND.FAIL,
//                      lines released for 100-101 ms, then a bus reset and a
//                      new attempt that reaches RUN with ERR / STEP cleared
//                      and ATTEMPT cleared by the first answered poll. Two
//                      silent SET_CONFIGURATION status stages followed by an
//                      answer do not fail step 6.
//
// Doc "Attempts", "Transactions", "Enumeration", "Register map".
//----------------------------------------------------------------------------

reg [31:0] fs_v;
integer    fs_oe_hits = 0;            // host drives seen while in BACKOFF

// The lines stay released for the whole BACKOFF: a host drive (keep-alive
// included) seen 1 ns after it starts, with the port still in BACKOFF
always @(posedge usb_oe)
  begin
     #1;
     if (tb_state === S_BACKOFF) fs_oe_hits = fs_oe_hits + 1;
  end

// True when state b directly follows state a in the history
function fs_follows;
   input [3:0] a;
   input [3:0] b;
   integer     k;
   begin
      fs_follows = 1'b0;
      for (k = 0; (k + 1 < st_n) && (k + 1 < STH); k = k + 1)
        if ((st_hist[k] == a) && (st_hist[k + 1] == b)) fs_follows = 1'b1;
   end
endfunction

// One failing attempt and its successful retry. The fault rules are already
// injected (slots 0 and 1); hits0 / hits1 (-1: unused) are the occurrences
// each rule must have faulted. open: the fault leaves a control transfer
// open, which the bus reset after BACKOFF then abandons.
task fs_scenario;
   input          restart;            // 1: CMD.RESTART from RUN, 0: attach
   input    [3:0] err;
   input    [3:0] step;
   input integer  hits0;
   input integer  hits1;
   input          open;
   begin
      // A step that fails on a STALL or a corrupted / overlong IN leaves its
      // control transfer without a status stage; the bus reset after BACKOFF
      // legally abandons it (USB 2.0 8.5.3, doc "Attempts"): the model's
      // STATUS checker is off from the fault to the end of that reset.
      if (open) dev.chk_enable(dev.C_STATUS, 0);
      wr(R_IRQ_PEND, I_ALL);
      st_hist_clear;
      fs_oe_hits = 0;
      if (restart) wr(R_CMD, K_RESTART);
      else         dev.attach(-1);
      wait_state(S_BACKOFF, 800.0);
      status_chk(S_BACKOFF, err, step);
      rdv(R_STATUS, fs_v);
      chk(f_attempt(fs_v) == 2'd1, "ATTEMPT 1 after the first failure");
      irq_chk(I_FAIL, I_FAIL);
      wait_state(S_RESET, 102.0);
      chk(fs_oe_hits == 0, "lines released during BACKOFF");
      chk_range(st_dur_last(S_BACKOFF), T_BACKOFF, T_BACKOFF + T_MS + T_LAT, "BACKOFF length");
      wait_state(S_RECOVERY, 62.0);
      dev.chk_enable(dev.C_STATUS, 1);
      wait_state(S_RUN, 600.0);
      chk(st_count(S_BACKOFF) == 1, "one failure, the retry succeeds");
      chk(fs_follows(S_ENUM, S_BACKOFF) && fs_follows(S_BACKOFF, S_RESET), "ENUM -> BACKOFF -> RESET");
      chk(!st_seen(S_FAILED), "FAILED not entered");
      status_chk(S_RUN, E_NONE, 4'd0);
      rd(R_DEV_ID, 32'h0001_1209);
      chk((dev_address == 7'd1) && dev_configured, "device at address 1 and configured");
      // The device NAKs the polls (no report queued): the first answered poll
      // clears ATTEMPT (bInterval 10 ms)
      wait_ms(15.0);
      rdv(R_STATUS, fs_v);
      chk(f_attempt(fs_v) == 2'd0, "ATTEMPT cleared by the first answered poll");
      chk(f_state(fs_v) == S_RUN, "still in RUN");
      chk(dev.fr_hits[0] == hits0, "fault rule 0 hit count");
      if (hits1 >= 0)
        chk(dev.fr_hits[1] == hits1, "fault rule 1 hit count");
      dev.clear_faults;
   end
endtask

initial
   begin
      wait_reset_done(5);
      dev.load_profile(dev.P_KBD);
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0);
      wait_state(S_DETACHED, 1.0);
      wait_ms(2.0);

      // Step 1: STALL of the GET_DESCRIPTOR(DEVICE) data stage (ERR 4)
      dev.inject_fault(dev.F_STALL, dev.T_IN, 0, 6, 1, dev.ST_DATA, 0, 1, 0);
      fs_scenario(1'b0, E_STALL, 4'd1, 1, -1, 1'b1);

      // Step 3: three silent SET_ADDRESS status stages (ERR 1); in the retry,
      // two silent SET_CONFIGURATION status stages then an answer: the
      // transaction is retried in the next frame and step 6 does not fail
      dev.inject_fault(dev.F_SILENT, dev.T_IN, 0, 5, -1, dev.ST_STATUS, 0, 3, 0);
      dev.inject_fault(dev.F_SILENT, dev.T_IN, 0, 9, -1, dev.ST_STATUS, 0, 2, 0);
      fs_scenario(1'b1, E_TIMEOUT, 4'd3, 3, 2, 1'b1);

      // Step 4: three CRC errors on its first data packet (ERR 2); skip 1
      // passes the single data packet of step 1
      dev.inject_fault(dev.F_CRC, dev.T_IN, 0, 6, 1, dev.ST_DATA, 1, 3, 0);
      fs_scenario(1'b1, E_CRC, 4'd4, 3, -1, 1'b1);

      // Step 1: three overlong data packets (ERR 3, packet too long)
      dev.inject_fault(dev.F_OVERLONG, dev.T_IN, 0, 6, 1, dev.ST_DATA, 0, 3, 12);
      fs_scenario(1'b1, E_UNEXPECTED, 4'd1, 3, -1, 1'b1);

      // Step 5: STALL of the GET_DESCRIPTOR(CONFIGURATION) data stage (ERR 4)
      dev.inject_fault(dev.F_STALL, dev.T_IN, 0, 6, 2, dev.ST_DATA, 0, 1, 0);
      fs_scenario(1'b1, E_STALL, 4'd5, 1, -1, 1'b1);

      stimulus_done = 1;
   end
