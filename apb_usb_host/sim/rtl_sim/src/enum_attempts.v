//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    enum_attempts
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : enum_attempts.v
// Module Description : A device that never answers the step-1 SETUP: two
//                      BACKOFF visits (ATTEMPT 1, then 2; 100-101 ms, lines
//                      released, each followed by a bus reset) and the third
//                      failure entering FAILED directly, IRQ_PEND.FAIL on
//                      every entry. FAILED keeps the lines released and waits
//                      for a detach; ERR / STEP survive DETACHED; a new
//                      attach gives a fresh debounce with ATTEMPT 0 and, the
//                      fault removed, enumeration reaches RUN.
//
// Doc "States", "Attempts", "Transactions", "Register map".
//----------------------------------------------------------------------------

reg [31:0] at_v;
integer    at_k;
integer    at_oe_hits = 0;            // host drives seen in BACKOFF or FAILED
reg  [3:0] at_exp [0:12];

// A host drive (keep-alive included) seen 1 ns after it starts, with the
// port still in BACKOFF or FAILED
always @(posedge usb_oe)
  begin
     #1;
     if ((tb_state === S_BACKOFF) || (tb_state === S_FAILED)) at_oe_hits = at_oe_hits + 1;
  end

// One BACKOFF visit: its ERR / STEP / ATTEMPT, the FAIL interrupt, its length
task at_backoff;
   input [1:0] attempt;
   begin
      wait_state(S_BACKOFF, 300.0);
      status_chk(S_BACKOFF, E_TIMEOUT, 4'd1);
      rdv(R_STATUS, at_v);
      chk(f_attempt(at_v) == attempt, "ATTEMPT in BACKOFF");
      irq_chk(I_FAIL, I_FAIL);
      wait_state(S_RESET, 102.0);
      chk_range(st_dur_last(S_BACKOFF), T_BACKOFF, T_BACKOFF + T_MS + T_LAT, "BACKOFF length");
   end
endtask

initial
   begin
      wait_reset_done(5);
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0);
      wait_state(S_DETACHED, 1.0);
      wait_ms(2.0);
      wr(R_IRQ_PEND, I_ALL);
      st_hist_clear;

      // Every GET_DESCRIPTOR(DEVICE) SETUP unanswered: step 1 fails with
      // three response timeouts in every attempt. The SETUP is never
      // accepted, so no control transfer is left open.
      dev.inject_fault(dev.F_SILENT, dev.T_SETUP, 0, 6, 1, dev.ST_SETUP, 0, -1, 0);
      dev.attach(dev.P_KBD);

      at_backoff(2'd1);
      at_backoff(2'd2);
      wait_state(S_FAILED, 300.0);
      status_chk(S_FAILED, E_TIMEOUT, 4'd1);
      irq_chk(I_FAIL, I_FAIL);

      // The state sequence: three attempts, the third failure straight to
      // FAILED (no second bus reset: step 1 never completes)
      at_exp[0]  = S_DEBOUNCE; at_exp[1]  = S_RESET;   at_exp[2]  = S_RECOVERY; at_exp[3]  = S_ENUM;
      at_exp[4]  = S_BACKOFF;  at_exp[5]  = S_RESET;   at_exp[6]  = S_RECOVERY; at_exp[7]  = S_ENUM;
      at_exp[8]  = S_BACKOFF;  at_exp[9]  = S_RESET;   at_exp[10] = S_RECOVERY; at_exp[11] = S_ENUM;
      at_exp[12] = S_FAILED;
      chk(st_n == 13, "13 state changes from the attach to FAILED");
      for (at_k = 0; (at_k < 13) && (at_k < st_n); at_k = at_k + 1)
        if (st_hist[at_k] != at_exp[at_k])
          begin
             $display("ERROR: state change %0d is %0s, expected %0s %t ns", at_k, st_name(st_hist[at_k]),
                      st_name(at_exp[at_k]), $time);
             error = error + 1;
          end

      // FAILED waits for a disconnect with the lines released
      wait_ms(30.0);
      status_chk(S_FAILED, E_TIMEOUT, 4'd1);
      chk(at_oe_hits == 0, "lines released in BACKOFF and FAILED");
      chk(usb_oe === 1'b0, "lines released in FAILED");
      chk(dev_suspended === 1'b1, "no keep-alive in FAILED: the device suspends");

      // Detach: DETACHED, the trace of the failure survives
      dev.detach;
      wait_state(S_DETACHED, 2.0);
      status_chk(S_DETACHED, E_TIMEOUT, 4'd1);
      wait_ms(2.0);

      // Attach again without the fault: fresh debounce, ATTEMPT 0, RUN
      dev.clear_faults;
      st_hist_clear;
      dev.attach(-1);
      wait_state(S_DEBOUNCE, 2.0);
      wait_ms(1.0);
      rdv(R_STATUS, at_v);
      chk(f_attempt(at_v) == 2'd0, "ATTEMPT cleared on entry to DEBOUNCE");
      wait_state(S_RUN, 400.0);
      chk(!st_seen(S_BACKOFF), "no failure after the fault is removed");
      chk_range(st_dur_last(S_DEBOUNCE), T_DEBOUNCE, T_DEBOUNCE + T_MS + T_LAT, "DEBOUNCE length");
      status_chk(S_RUN, E_NONE, 4'd0);
      rd(R_DEV_ID, 32'h0001_1209);
      stimulus_done = 1;
   end
