//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    enum_lost_ack
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : enum_lost_ack.v
// Module Description : Lost handshakes during one keyboard enumeration, each
//                      a single transaction error that must not fail its
//                      step (USB 2.0 8.6.3, 8.6.4). The device's ACK of the
//                      SET_CONFIGURATION SETUP corrupted: the host resends
//                      the SETUP, the device accepts it again. The device's
//                      ACK of the step-4 and step-5 status OUT corrupted:
//                      the host resends the status packet, the device ACKs
//                      the duplicate. A lost host ACK on the second step-5
//                      data packet, as the host sees it: the device resends
//                      a packet with the previous toggle, which the host
//                      must acknowledge and discard, so the descriptor is
//                      parsed without a duplicated chunk. Enumeration
//                      completes with the keyboard's DEV_* values; with
//                      DIAG_EN the counters show the three PID-check errors
//                      and the one discarded packet. With CTRL_EN, the
//                      device's ACK of the first OUT data packet of a 9-byte
//                      SET_REPORT corrupted: the device discards the
//                      retransmission and receives the 9 bytes once.
//
// Doc "Transactions", "Enumeration", "Control transfers", "Register map".
//----------------------------------------------------------------------------

reg [31:0] la_v;
integer    la_k;
integer    la_n;
integer    la_srep0;
reg  [7:0] la_seq;
reg  [6:0] la_len;
reg [63:0] la_d;

// Wait until XFER.PKT is set (bit 8), polling every 100 us, at most 50 ms
task la_wait_pkt;
   begin
      la_n = 0;
      rdv(R_XFER, la_v);
      while (!la_v[8] && (la_n < 500))
        begin
           #(100.0e3);
           rdv(R_XFER, la_v);
           la_n = la_n + 1;
        end
      chk(la_v[8] === 1'b1, "XFER.PKT set");
   end
endtask

initial
   begin
      wait_reset_done(5);
      dev.load_profile(dev.P_KBD);
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0);
      wait_state(S_DETACHED, 1.0);
      wait_ms(2.0);
      st_hist_clear;

      // Slot 0: the ACK of the SET_CONFIGURATION SETUP, PID check bits wrong
      dev.inject_fault(dev.F_PID, dev.T_SETUP, 0, 9, -1, dev.ST_SETUP, 0, 1, 0);
      // Slot 1: the ACK of the step-4 status OUT (skip 1: step 1's status OUT)
      dev.inject_fault(dev.F_CRC, dev.T_OUT, 0, 6, 1, dev.ST_STATUS, 1, 1, 0);
      // Slot 2: the second step-5 data packet sent with the previous toggle
      dev.inject_fault(dev.F_TOGGLE, dev.T_IN, 0, 6, 2, dev.ST_DATA, 1, 1, 0);
      // Slot 3: the ACK of the step-5 status OUT
      dev.inject_fault(dev.F_PID, dev.T_OUT, 0, 6, 2, dev.ST_STATUS, 0, 1, 0);
      dev.attach(-1);
      wait_state(S_RUN, 600.0);

      chk(!st_seen(S_BACKOFF), "lost handshakes: no failure");
      chk(st_count(S_RESET) == 2, "two bus resets");
      status_chk(S_RUN, E_NONE, 4'd0);
      for (la_k = 0; la_k < 4; la_k = la_k + 1)
        if (dev.fr_hits[la_k] != 1)
          begin
             $display("ERROR: fault rule %0d hit %0d times, expected 1 %t ns", la_k, dev.fr_hits[la_k], $time);
             error = error + 1;
          end
      rd(R_DEV_ID, 32'h0001_1209);
      rd(R_DEV_IF, {7'h0, 1'b1, 8'd1, 8'd1, 8'd0});
      rd(R_DEV_EP, {1'b0, 7'd8, 8'd10, 5'h00, 7'd8, 4'd1});
      chk((dev_address == 7'd1) && dev_configured, "device at address 1 and configured");
      chk(dev.hid_proto[0] == 0, "boot protocol set");
      read_report(la_len, la_seq, la_d);
      dev.push_report(8, 64'h0000_0000_0004_0000);
      expect_report(la_seq, 8, 64'h0000_0000_0004_0000, 40.0);

      // Three corrupted handshakes (PID check), one IN discarded for its toggle
      if (DIAG_EN != 0)
        begin
           rdv(R_DIAG0, la_v);
           chk32(la_v, 32'h0000_0300, "DIAG0: three CRC / stuffing / PID-check errors");
           rdv(R_DIAG1, la_v);
           chk32({16'h0, la_v[31:16]}, 32'h1, "DIAG1: one IN packet discarded for its toggle");
        end
      dev.clear_faults;

      // Software SET_REPORT of 9 bytes (two OUT packets); the device's ACK of
      // the first one corrupted
      if (CTRL_EN != 0)
        begin
           la_srep0 = dev.srep_cnt;
           dev.inject_fault(dev.F_CRC, dev.T_OUT, 0, 9, 2, dev.ST_DATA, 0, 1, 0);
           wr(R_SETUP0, 32'h0200_0921);              // class, interface; SET_REPORT; output report 0
           wr(R_SETUP1, 32'h0009_0000);              // interface 0, wLength 9
           wr(R_CMD, K_XFER_START);
           la_wait_pkt;
           wr(R_XDATA0,     32'h4433_2211);
           wr(R_XDATA0 + 4, 32'h8877_6655);
           wr(R_XFER, 32'd8);
           wr(R_CMD, K_XFER_NEXT);
           la_wait_pkt;
           wr(R_XDATA0, 32'h0000_0099);
           wr(R_XFER, 32'd1);
           wr(R_CMD, K_XFER_NEXT);
           la_n = 0;
           rdv(R_STATUS, la_v);
           while (f_xbusy(la_v) && (la_n < 500))
             begin
                #(100.0e3);
                rdv(R_STATUS, la_v);
                la_n = la_n + 1;
             end
           chk(!f_xbusy(la_v), "SET_REPORT done");
           rdv(R_XFER, la_v);
           chk(la_v[11:9] == X_OK, "XFER.RESULT OK");
           chk(dev.fr_hits[0] == 1, "the OUT handshake was corrupted once");
           chk(dev.srep_cnt == la_srep0 + 1, "one SET_REPORT received");
           chk(dev.srep_len == 9, "SET_REPORT of 9 bytes: the duplicate discarded");
           chk((dev.srep[0] == 8'h11) && (dev.srep[7] == 8'h88) && (dev.srep[8] == 8'h99), "SET_REPORT data");
           status_chk(S_RUN, E_NONE, 4'd0);
           dev.clear_faults;
        end
      stimulus_done = 1;
   end
