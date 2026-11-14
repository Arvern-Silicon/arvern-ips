//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    diag_counters
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : diag_counters.v
// Module Description : The diagnostic counters (DIAG_EN=1): a STALL of the
//                      optional step 7 counts one STALL and the enumeration
//                      two bus resets; in RUN, single faults on the polled
//                      endpoint, each retried before it can fail the poll,
//                      count exactly once each: response timeouts, PID-check,
//                      CRC and bit-stuffing errors, a packet too long (other
//                      errors), an IN packet with the wrong toggle (DIAG1,
//                      not a transaction error, delivered once); the timeout
//                      count saturates at 255 without touching the other
//                      fields; a DIAG0 write clears DIAG0 and DIAG1.
//
// Doc "Register map" (DIAG0, DIAG1), "Transactions", "Enumeration",
// "Polling", "Attempts".
//----------------------------------------------------------------------------

integer    dg_i;
integer    dg_b;
reg [31:0] dg_d0;                            // expected DIAG0
reg [31:0] dg_d1;                            // expected DIAG1
reg  [7:0] dg_seq;
reg  [6:0] dg_len;
reg [63:0] dg_dat;
reg [31:0] dg_v;
real       dg_t0;

// Wait until fault rule 0 has fired n times (at most ms)
task dg_wait_hits;
   input integer n;
   input real    ms;
   real          t0;
   begin
      t0 = $realtime;
      while ((dev.fr_hits[0] < n) && ($realtime - t0 < ms * T_MS))
        #(50.0e3);
      if (dev.fr_hits[0] < n)
        begin
           $display("ERROR: fault fired %0d time(s), expected %0d within %0.1f ms %t ns", dev.fr_hits[0], n, ms, $time);
           error = error + 1;
        end
   end
endtask

task dg_chk;
   input [80*8-1:0] msg;
   begin
      rdv(R_DIAG0, dg_v);
      chk32(dg_v, dg_d0, msg);
      rdv(R_DIAG1, dg_v);
      chk32(dg_v, dg_d1, msg);
      status_chk(S_RUN, 4'hF, 4'hF);
   end
endtask

// count consecutive faults of kind on IN EP1 while it answers NAK, then a NAK
task dg_nak_fault;
   input integer kind;
   input integer count;
   begin
      dev.clear_faults;
      dev.inject_fault(kind, dev.T_IN, 1, -1, -1, -1, 0, count, 0);
      dg_wait_hits(count, 50.0);
      wait_ms(5.0);
   end
endtask

// One fault of kind on the data packet of a queued report, then the report
// delivered once, by the retry
task dg_data_fault;
   input integer kind;
   input integer arg;
   input [63:0]  data;
   begin
      dev.clear_faults;
      read_report(dg_len, dg_seq, dg_dat);
      dev.inject_fault(kind, dev.T_IN, 1, -1, -1, -1, 0, 1, arg);
      dev.push_report(8, data);
      dg_wait_hits(1, 50.0);
      expect_report(dg_seq, 8, data, 50.0);
      wait_ms(5.0);
      read_report(dg_len, dg_v[7:0], dg_dat);
      chk(dg_v[7:0] == dg_seq + 8'd1, "the report is committed once");
   end
endtask

initial
   begin
      wait_reset_done(5);
      if (DIAG_EN == 0)
        begin
           rd(R_DIAG0, 32'h0);
           rd(R_DIAG1, 32'h0);
           tb_skip("DIAG_EN = 0: no diagnostic counters");
        end
      rd(R_DIAG0, 32'h0);
      rd(R_DIAG1, 32'h0);

      // Enumeration: the device STALLs SET_PROTOCOL in its status stage (step 7
      // may be refused, the sequence goes on); IDLE0 = 0, so no SETUP follows
      // the stalled transfer
      dev.inject_fault(dev.F_STALL, dev.T_IN, 0, 11, -1, dev.ST_STATUS, 0, 1, 0);
      wr(R_CTRL, C_EN | C_BOOT);
      dev.attach(dev.P_KBD);
      wait_state(S_RUN, 600.0);
      chk(dev.fr_hits[0] == 1, "SET_PROTOCOL stalled once");
      rd(R_DEV_IF, {7'h0, 1'b0, 8'd1, 8'd1, 8'd0});        // BOOT 0: step 7 refused
      dg_d0 = {8'd1, 8'd0, 8'd0, 8'd0};
      dg_d1 = {16'd0, 16'd2};
      dg_chk("after the enumeration: one STALL, two bus resets");

      // A write clears both
      wr(R_DIAG0, 32'h0000_0000);
      dg_d0 = 32'h0;
      dg_d1 = 32'h0;
      dg_chk("cleared by the DIAG0 write");

      // Poll every frame
      wr(R_CTRL, C_EN | C_BOOT | (32'd1 << 8));
      wait_ms(15.0);
      dg_chk("no count while the device answers NAK");

      // Response timeouts: two in a row, then a NAK
      dg_nak_fault(dev.F_SILENT, 2);
      dg_d0[7:0] = dg_d0[7:0] + 8'd2;
      dg_chk("two response timeouts");

      // PID check bits of the NAK
      dg_nak_fault(dev.F_PID, 2);
      dg_d0[15:8] = dg_d0[15:8] + 8'd2;
      dg_chk("two PID-check errors");

      // CRC16 and bit stuffing of a data packet
      dg_data_fault(dev.F_CRC, 0, 64'h0000_0000_0004_0000);
      dg_d0[15:8] = dg_d0[15:8] + 8'd1;
      dg_chk("one CRC error");
      dg_data_fault(dev.F_STUFF, 0, 64'h0000_0000_0005_0000);
      dg_d0[15:8] = dg_d0[15:8] + 8'd1;
      dg_chk("one bit-stuffing error");

      // A data packet longer than 8 bytes: an other transaction error
      dg_data_fault(dev.F_OVERLONG, 9, 64'h0000_0000_0006_0000);
      dg_d0[23:16] = dg_d0[23:16] + 8'd1;
      dg_chk("one packet too long");

      // Wrong toggle: acknowledged and discarded, counted in DIAG1, not an error
      dg_data_fault(dev.F_TOGGLE, 0, 64'h0000_0000_0007_0000);
      dg_d1[31:16] = dg_d1[31:16] + 16'd1;
      dg_chk("one IN packet discarded for its toggle");

      // Saturation of the timeout count: bursts of two timeouts and a NAK, 16
      // rules per batch (each rule counts every IN on EP1)
      for (dg_b = 0; dg_b < 8; dg_b = dg_b + 1)
        begin
           dev.clear_faults;
           for (dg_i = 0; dg_i < 16; dg_i = dg_i + 1)
             dev.inject_fault(dev.F_SILENT, dev.T_IN, 1, -1, -1, -1, 3 * dg_i, 2, 0);
           dg_t0 = $realtime;
           while ((dev.fr_occ[15] < 48) && ($realtime - dg_t0 < 200.0 * T_MS)) #(100.0e3);
           chk(dev.fr_occ[15] >= 48, "a batch of 48 polls within 200 ms");
           chk(tb_state === S_RUN, "timeouts never fail the poll");
        end
      dev.clear_faults;
      wait_ms(3.0);
      dg_d0[7:0] = 8'd255;
      dg_chk("timeout count saturated at 255");

      // A write clears both again
      apb_write(1, MACHINE, R_DIAG0, $urandom, SZ_W, OK);
      dg_d0 = 32'h0;
      dg_d1 = 32'h0;
      dg_chk("cleared by the DIAG0 write");

      stimulus_done = 1;
   end
