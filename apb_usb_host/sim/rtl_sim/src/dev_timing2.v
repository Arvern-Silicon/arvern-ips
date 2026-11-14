//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dev_timing2
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dev_timing2.v
// Module Description : Device response delay at the edges of its legal range
//                      (2 and 6.5 bit times) at the nominal bit rate, then
//                      the shortest delay at -1.5 % and +1.5 % bit rate
//                      (dev_timing.v has the longest). Per corner: a clean
//                      enumeration (no failure, device information right,
//                      boot protocol set), five reports including all-ones
//                      (maximum stuffing) and all-zeros bytes, no
//                      transaction error (DIAG_EN), then a detach.
//
// Doc "Bus timing" (receiver), "Transactions", "Enumeration", "Polling".
// USB 2.0 7.1.11, 7.1.18.
//----------------------------------------------------------------------------

reg [31:0] dt_v;
reg  [7:0] dt_seq;
reg  [6:0] dt_len;
reg [63:0] dt_d;

// One corner: enumerate, five reports, detach
task dt_corner;
   input integer ppm;
   input integer dmin;
   input integer dmax;
   begin
      $display("[%0t] corner: device rate %0d ppm, response delay %0d..%0d/100 bit", $time, ppm, dmin, dmax);
      dev.set_rate_ppm(ppm);
      dev.set_resp_delay(dmin, dmax);
      st_hist_clear;
      if (DIAG_EN != 0) wr(R_DIAG0, 32'h0);
      dev.attach(dev.P_KBD);
      wait_state(S_RUN, 600.0);
      chk(!st_seen(S_BACKOFF), "clean enumeration");
      status_chk(S_RUN, E_NONE, 4'd0);
      rd(R_DEV_ID, 32'h0001_1209);
      rd(R_DEV_IF, {7'h0, 1'b1, 8'd1, 8'd1, 8'd0});
      rd(R_DEV_EP, {1'b0, 7'd8, 8'd10, 5'h00, 7'd8, 4'd1});

      read_report(dt_len, dt_seq, dt_d);
      chk(dt_seq == 8'd0, "no report yet");
      dev.push_report(8, 64'hFFFF_FFFF_FFFF_FFFF);
      expect_report(dt_seq, 8, 64'hFFFF_FFFF_FFFF_FFFF, 30.0);
      dt_seq = dt_seq + 8'd1;
      dev.push_report(8, 64'h0);
      expect_report(dt_seq, 8, 64'h0, 30.0);
      dt_seq = dt_seq + 8'd1;
      dev.push_report(8, 64'h7F3E_01FE_807F_C001);
      expect_report(dt_seq, 8, 64'h7F3E_01FE_807F_C001, 30.0);
      dt_seq = dt_seq + 8'd1;
      dev.push_report(3, 64'h0000_0000_00FF_7E81);
      expect_report(dt_seq, 3, 64'h0000_0000_00FF_7E81, 30.0);
      dt_seq = dt_seq + 8'd1;
      dev.push_report(1, 64'h0000_0000_0000_003F);
      expect_report(dt_seq, 1, 64'h0000_0000_0000_003F, 30.0);

      chk(!st_seen(S_BACKOFF), "no failure while polling");
      if (DIAG_EN != 0)
        begin
           rdv(R_DIAG0, dt_v);
           chk(dt_v[23:0] == 24'h0, "no timeout, CRC/stuffing/PID or other transaction error");
           rdv(R_DIAG1, dt_v);
           chk(dt_v == 32'h0000_0002, "two bus resets, no packet discarded for its toggle");
        end
      dev.detach;
      wait_state(S_DETACHED, 5.0);
      wait_ms(2.0);
   end
endtask

initial
   begin
      wait_reset_done(5);
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0 | (32'd2 << 8));
      wait_state(S_DETACHED, 1.0);
      dt_corner(     0, 200, 200);
      dt_corner(     0, 650, 650);
      dt_corner(-15000, 200, 200);
      dt_corner( 15000, 200, 200);
      stimulus_done = 1;
   end
