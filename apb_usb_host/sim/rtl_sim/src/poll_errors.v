//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    poll_errors
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : poll_errors.v
// Module Description : Transient poll errors. One or two consecutive faults
//                      on the report packet (silent, CRC16, overlong, PID
//                      check) are retried and the report is delivered with
//                      no failure. Three consecutive ones, or one STALL,
//                      fail the poll: BACKOFF with ERR per kind, STEP 0,
//                      ATTEMPT 1, IRQ_PEND.FAIL, then RESET and a new
//                      enumeration without debounce, and the report still
//                      queued in the device is delivered with SEQ restarted.
//                      The five failures come one after the other, each
//                      followed by an answered poll that clears ATTEMPT: the
//                      port never reaches FAILED. With DIAG_EN the per-kind
//                      counters follow.
//
// Doc "Polling", "Transactions", "Attempts", "Register map" (STATUS, DIAG0).
//----------------------------------------------------------------------------

integer    pe_k, pe_c, pe_f0, pe_n;
integer    pe_kind [0:4];
reg  [3:0] pe_err  [0:4];
integer    pe_fld  [0:4];               // DIAG0 byte counting the kind
reg [31:0] pe_v;
reg [63:0] pe_d;
reg  [7:0] pe_seq;
reg  [6:0] pe_len;
reg [31:0] pe_ctrl;

// DIAG0: the byte of the kind holds n, the other error bytes 0 (STALLs in [31:24])
task pe_diag_chk;
   input integer fld;
   input integer n;
   integer       b;
   reg    [31:0] dv;
   begin
      if (DIAG_EN != 0)
        begin
           rdv(R_DIAG0, dv);
           for (b = 0; b < 4; b = b + 1)
             if (dv[8*b +: 8] != ((b == fld) ? n : 0))
               begin
                  $display("ERROR: DIAG0[%0d:%0d] = %0d, expected %0d (DIAG0 0x%h) %t ns", 8*b+7, 8*b,
                           dv[8*b +: 8], (b == fld) ? n : 0, dv, $time);
                  error = error + 1;
               end
        end
   end
endtask

initial
   begin
      wait_reset_done(5);
      pe_kind[0] = dev.F_SILENT;   pe_err[0] = E_TIMEOUT;    pe_fld[0] = 0;
      pe_kind[1] = dev.F_CRC;      pe_err[1] = E_CRC;        pe_fld[1] = 1;
      pe_kind[2] = dev.F_OVERLONG; pe_err[2] = E_UNEXPECTED; pe_fld[2] = 2;
      pe_kind[3] = dev.F_PID;      pe_err[3] = E_CRC;        pe_fld[3] = 1;
      pe_kind[4] = dev.F_STALL;    pe_err[4] = E_STALL;      pe_fld[4] = 3;
      pe_ctrl = C_EN | C_BOOT | C_IDLE0 | (32'd2 << 8);
      enumerate(dev.P_KBD, pe_ctrl, 600.0);
      wait_ms(5.0);

      // One and two consecutive errors: retried in the next frames, no failure
      for (pe_k = 0; pe_k < 4; pe_k = pe_k + 1)
        for (pe_c = 1; pe_c <= 2; pe_c = pe_c + 1)
          begin
             read_report(pe_len, pe_seq, pe_d);
             if (DIAG_EN != 0) wr(R_DIAG0, 32'h0);
             pe_d  = 64'h8877_6655_4433_2200 + 16 * pe_k + pe_c;
             pe_f0 = dev.st_faults;
             dev.push_report(8, pe_d);
             dev.inject_fault(pe_kind[pe_k], dev.T_IN, 1, -1, -1, -1, 0, pe_c, 12);
             expect_report(pe_seq, 8, pe_d, 40.0);
             chk(dev.st_faults - pe_f0 == pe_c, "every programmed fault hit the report packet");
             rdv(R_STATUS, pe_v);
             chk(f_state(pe_v) == S_RUN,    "transient errors: still RUN");
             chk(f_err(pe_v) == E_NONE,     "transient errors: no failure recorded");
             chk(f_attempt(pe_v) == 2'd0,   "transient errors: ATTEMPT 0");
             pe_diag_chk(pe_fld[pe_k], pe_c);
             dev.clear_faults;
          end
      chk(!st_seen(S_BACKOFF), "no failure from transient errors");

      // Three errors / one STALL: a failure; the device then works again
      for (pe_k = 0; pe_k < 5; pe_k = pe_k + 1)
        begin
           st_hist_clear;
           wr(R_IRQ_PEND, I_ALL);
           if (DIAG_EN != 0) wr(R_DIAG0, 32'h0);
           pe_n  = (pe_kind[pe_k] == dev.F_STALL) ? 1 : 3;
           pe_d  = 64'h0123_4567_89AB_CD00 + pe_k;
           pe_f0 = dev.st_faults;
           dev.push_report(8, pe_d);
           dev.inject_fault(pe_kind[pe_k], dev.T_IN, 1, -1, -1, -1, 0, pe_n, 12);
           wait_state(S_BACKOFF, 40.0);
           rdv(R_STATUS, pe_v);
           chk(f_state(pe_v) == S_BACKOFF, "failed poll: BACKOFF");
           if (f_err(pe_v) != pe_err[pe_k])
             begin
                $display("ERROR: STATUS.ERR %0d after a failed poll (fault %0d), expected %0d %t ns",
                         f_err(pe_v), pe_kind[pe_k], pe_err[pe_k], $time);
                error = error + 1;
             end
           chk(f_step(pe_v) == 4'd0,    "failed poll: STEP 0");
           chk(f_attempt(pe_v) == 2'd1, "failed poll after an answered poll: ATTEMPT 1");
           chk(dev.st_faults - pe_f0 == pe_n, "the poll failed on its last programmed fault");
           irq_chk(I_FAIL, I_FAIL);
           pe_diag_chk(pe_fld[pe_k], pe_n);
           rd(R_REPORT_INFO, 32'h0);
           dev.clear_faults;

           wait_state_not(S_BACKOFF, 102.0);
           #1;
           chk(tb_state == S_RESET, "BACKOFF leads to RESET");
           wait_state(S_RUN, 400.0);
           chk_range(st_dur_last(S_BACKOFF), T_BACKOFF, T_BACKOFF + T_MS + T_LAT, "BACKOFF length");
           chk(!st_seen(S_DEBOUNCE), "re-enumeration without a new debounce");
           chk(!st_seen(S_FAILED),   "a failure after an answered poll never reaches FAILED");
           status_chk(S_RUN, E_NONE, 4'd0);

           // The queued report is the first one after the new enumeration
           expect_report(8'd0, 8, pe_d, 40.0);
           rdv(R_STATUS, pe_v);
           chk(f_attempt(pe_v) == 2'd0, "the answered poll clears ATTEMPT");
           chk(f_state(pe_v) == S_RUN,  "still RUN");
        end
      stimulus_done = 1;
   end
