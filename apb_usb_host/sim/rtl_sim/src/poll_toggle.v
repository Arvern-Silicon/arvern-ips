//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    poll_toggle
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : poll_toggle.v
// Module Description : Data toggle of the interrupt endpoint.
//                      - A report with the wrong toggle is ACKed and
//                        discarded: SEQ unchanged, no REPORT interrupt; the
//                        same report then comes with the right toggle and is
//                        committed.
//                      - A zero-length DATA packet is ACKed, not committed,
//                        and advances the toggle: the next report is
//                        committed.
//                      - A lost host ACK: the device sends the report it
//                        already delivered again, with the same toggle; the
//                        host ACKs and discards it, and its expected toggle
//                        does not move (the next report is committed).
//                      - Reports of 1 to 8 bytes, LEN and bytes checked.
//                      With DIAG_EN, DIAG1 counts the two discarded packets.
//
// Doc "Transactions" (Data toggle), "Polling", "Report buffer", "Register map".
// USB 2.0 8.6.4.
//----------------------------------------------------------------------------

integer    pt_hs = 0;                   // host handshakes decoded by the device
integer    pt_h0, pt_f0, pt_a0, pt_n;
real       pt_t0;
reg [31:0] pt_v;
reg [63:0] pt_d, pt_r;
reg  [7:0] pt_seq, pt_s2;
reg  [6:0] pt_len;

always @(posedge dev.ev_tgl or negedge dev.ev_tgl)
  if (dev.last_ev == dev.LE_HHS) pt_hs = pt_hs + 1;

// Wait until the device has applied a fault rule (at most 20 ms), then 200 us
task pt_wait_fault;
   begin
      pt_t0 = $realtime;
      while ((dev.st_faults == pt_f0) && ($realtime - pt_t0 < 20.0 * T_MS)) #(5.0e3);
      chk(dev.st_faults == pt_f0 + 1, "the fault rule was applied once");
      #(200.0e3);
   end
endtask

// The window still shows SEQ s and no REPORT is pending
task pt_not_committed;
   input [7:0] s;
   begin
      read_report(pt_len, pt_s2, pt_r);
      chk(pt_s2 == s, "the packet is not committed (SEQ unchanged)");
      rdv(R_IRQ_PEND, pt_v);
      chk(pt_v[0] == 1'b0, "no IRQ_PEND.REPORT for a discarded packet");
   end
endtask

initial
   begin
      wait_reset_done(5);
      enumerate(dev.P_KBD, C_EN | C_BOOT | C_IDLE0 | (32'd2 << 8), 600.0);
      wait_ms(5.0);
      if (DIAG_EN != 0) wr(R_DIAG0, 32'h0);

      // A first report: the toggle of the endpoint is under way
      read_report(pt_len, pt_seq, pt_d);
      dev.push_report(8, 64'h1111_2222_3333_4444);
      expect_report(pt_seq, 8, 64'h1111_2222_3333_4444, 20.0);
      pt_seq = pt_seq + 8'd1;

      // Wrong toggle: ACKed and discarded, then delivered with the right one
      wr(R_IRQ_PEND, I_REPORT);
      pt_f0 = dev.st_faults;
      pt_h0 = pt_hs;
      dev.push_report(8, 64'hA5A5_0102_0304_0506);
      dev.inject_fault(dev.F_TOGGLE, dev.T_IN, 1, -1, -1, -1, 0, 1, 0);
      pt_wait_fault;
      chk(pt_hs == pt_h0 + 1, "the host ACKs a packet with the wrong toggle");
      pt_not_committed(pt_seq);
      expect_report(pt_seq, 8, 64'hA5A5_0102_0304_0506, 20.0);
      pt_seq = pt_seq + 8'd1;
      dev.clear_faults;

      // Zero-length packet: ACKed, not committed, toggle advanced
      wr(R_IRQ_PEND, I_REPORT);
      pt_a0 = dev.int_ack_cnt;
      pt_h0 = pt_hs;
      dev.push_report(0, 64'h0);
      dev.push_report(8, 64'h0F0E_0D0C_0B0A_0908);
      pt_t0 = $realtime;
      while ((dev.int_ack_cnt == pt_a0) && ($realtime - pt_t0 < 20.0 * T_MS)) #(5.0e3);
      chk(dev.int_ack_cnt == pt_a0 + 1, "the zero-length packet is acknowledged");
      #(200.0e3);
      chk(pt_hs == pt_h0 + 1, "one host ACK for the zero-length packet");
      pt_not_committed(pt_seq);
      expect_report(pt_seq, 8, 64'h0F0E_0D0C_0B0A_0908, 20.0);
      pt_seq = pt_seq + 8'd1;

      // Lost host ACK: the delivered report again with its old toggle; once
      // the host has ACKed it, the device drops it (as on the ACK of a
      // retransmission) and the next report must be committed
      pt_d = 64'h7766_5544_3322_1100;
      dev.push_report(8, pt_d);
      expect_report(pt_seq, 8, pt_d, 20.0);
      pt_seq = pt_seq + 8'd1;
      wr(R_IRQ_PEND, I_REPORT);
      pt_f0 = dev.st_faults;
      pt_h0 = pt_hs;
      dev.push_report(8, pt_d);
      dev.inject_fault(dev.F_TOGGLE, dev.T_IN, 1, -1, -1, -1, 0, 1, 0);
      pt_wait_fault;
      dev.flush_reports;
      chk(pt_hs == pt_h0 + 1, "the host ACKs the retransmitted packet");
      pt_not_committed(pt_seq);
      dev.clear_faults;
      dev.push_report(8, 64'hFEDC_BA98_7654_3210);
      expect_report(pt_seq, 8, 64'hFEDC_BA98_7654_3210, 20.0);
      pt_seq = pt_seq + 8'd1;

      // Reports of 1 to 8 bytes
      for (pt_n = 1; pt_n <= 8; pt_n = pt_n + 1)
        begin
           pt_d = 64'hC3B2_A190_8F7E_6D5C ^ ({8{pt_n[7:0]}} << 1);
           dev.push_report(pt_n, pt_d);
           expect_report(pt_seq, pt_n, pt_d, 20.0);
           pt_seq = pt_seq + 8'd1;
        end

      if (DIAG_EN != 0)
        begin
           rdv(R_DIAG1, pt_v);
           chk(pt_v[31:16] == 16'd2, "DIAG1 counts the two packets discarded for their toggle");
           rdv(R_DIAG0, pt_v);
           chk(pt_v == 32'h0, "no transaction error");
        end
      chk(!st_seen(S_BACKOFF), "no failure");
      status_chk(S_RUN, E_NONE, 4'd0);
      stimulus_done = 1;
   end
