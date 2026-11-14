//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    enum_progress
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : enum_progress.v
// Module Description : The control-request progress timeout. A device that
//                      NAKs the step-1 data stage forever: ERR 5, step 1,
//                      BACKOFF entered 500-501 ms after the SETUP was
//                      accepted. In the retry, 300 NAKs of the step-5 data
//                      stage then the data: within the timeout, RUN. Then a
//                      device that NAKs the step-4 status stage forever:
//                      ERR 5, step 4, 500-501 ms after the last data packet.
//
// Doc "Transactions" (progress timeout), "Bus timing", "Enumeration".
//----------------------------------------------------------------------------

reg [31:0] pg_v;
real       pg_t;

// Progress as the device sees it: a SETUP accepted, a data packet
// acknowledged or accepted, a status stage completed (the model's timestamps)
function real pg_last_prog;
   input dummy;
   pg_last_prog = (dev.ctl_progress_t > dev.st_xfer_start_t) ? dev.ctl_progress_t : dev.st_xfer_start_t;
endfunction

// The host's progress event follows the device's by a response delay and a
// handshake (SETUP, OUT) or precedes it by its ACK (IN data): up to about
// 20 us either way, allowed for with 50 us
task pg_timeout_chk;
   input [3:0] step;
   begin
      wait_state(S_BACKOFF, 900.0);
      pg_t = $realtime;
      chk_range(pg_t - pg_last_prog(1'b0), 500.0 * T_MS - 50.0e3, 501.0 * T_MS + 50.0e3, "progress timeout");
      status_chk(S_BACKOFF, E_PROGRESS, step);
      rdv(R_STATUS, pg_v);
      chk(f_attempt(pg_v) == 2'd1, "ATTEMPT 1 after the timeout");
      irq_chk(I_FAIL, I_FAIL);
   end
endtask

initial
   begin
      wait_reset_done(5);
      dev.load_profile(dev.P_KBD);
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0);
      wait_state(S_DETACHED, 1.0);
      wait_ms(2.0);
      wr(R_IRQ_PEND, I_ALL);
      st_hist_clear;

      // The failed steps leave their control transfer open (NAKed data or
      // status stage); the bus reset of the next attempt legally abandons
      // it (USB 2.0 8.5.3, doc "Attempts"), which the model's STATUS checker
      // would count
      dev.chk_enable(dev.C_STATUS, 0);

      // Step-1 data stage NAKed forever
      dev.inject_fault(dev.F_NAK, dev.T_IN, 0, 6, 1, dev.ST_DATA, 0, -1, 0);
      dev.attach(-1);
      pg_timeout_chk(4'd1);
      chk(dev.fr_hits[0] >= 490, "the data stage was NAKed every frame");

      // Retry: 300 NAKs of the step-5 data stage, then the data
      dev.clear_faults;
      dev.inject_fault(dev.F_NAK, dev.T_IN, 0, 6, 2, dev.ST_DATA, 0, 300, 0);
      wait_state(S_RUN, 900.0);
      chk(st_count(S_BACKOFF) == 1, "NAKs within the timeout: no second failure");
      chk(dev.fr_hits[0] == 300, "300 NAKs");
      chk(st_dur_last(S_ENUM) >= 300.0 * T_MS, "ENUM lasted the NAKs");
      status_chk(S_RUN, E_NONE, 4'd0);
      rd(R_DEV_ID, 32'h0001_1209);
      rd(R_DEV_EP, {1'b0, 7'd8, 8'd10, 5'h00, 7'd8, 4'd1});

      // Step-4 status stage NAKed forever (skip 1: the step-1 status stage)
      dev.clear_faults;
      dev.inject_fault(dev.F_NAK, dev.T_OUT, 0, 6, 1, dev.ST_STATUS, 1, -1, 0);
      wr(R_IRQ_PEND, I_ALL);
      st_hist_clear;
      wr(R_CMD, K_RESTART);
      pg_timeout_chk(4'd4);
      chk(dev.fr_hits[0] >= 490, "the status stage was NAKed every frame");
      chk(usb_oe === 1'b0, "lines released in BACKOFF");
      // End with a detach, so the keep-alive gap of BACKOFF is closed
      dev.detach;
      wait_state(S_DETACHED, 2.0);

      stimulus_done = 1;
   end
