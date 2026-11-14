//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    report_buffer
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : report_buffer.v
// Module Description : The double report buffer under concurrent reads.
//                      POLL_MS = 1 and a fresh report pushed every ms, its
//                      bytes derived from the SEQ it will get (a table of
//                      the pushed reports is kept by SEQ). Around each
//                      report transaction software reads REPORT_INFO,
//                      REPORT[0], REPORT[1], REPORT_INFO back to back and
//                      retries when SEQ changed: every consistent read is
//                      exactly the report of its SEQ (LEN and bytes), SEQ
//                      never goes back, and some reads did see a swap.
//                      Then single reads of REPORT[0] / REPORT[1] across the
//                      swaps: every word holds four bytes of one report.
//                      REPORT[2..15] read 0. After a detach REPORT_INFO and
//                      the window read 0.
//
// Doc "Report buffer", "Polling", "Register map" (REPORT_INFO, REPORT).
//----------------------------------------------------------------------------

localparam RB_N1 = 150;                 // reports of the four-read phase
localparam RB_N2 = 80;                  // reports of the single-word phase

reg [63:0] rb_dat [0:255];              // pushed report by SEQ
reg  [6:0] rb_len [0:255];
reg        rb_ok  [0:255];
integer    rb_k, rb_b, rb_i, rb_np, rb_retry, rb_reads, rb_last;
integer    rb_s0;
reg        rb_push_done;
real       rb_t0;
reg [31:0] rb_i0, rb_i1, rb_w0, rb_w1, rb_v;
reg  [7:0] rb_s, rb_prev;
reg  [6:0] rb_l;
reg [63:0] rb_m;
integer    rb_dhs = 0;                  // device handshakes sent

always @(posedge dev.ev_tgl or negedge dev.ev_tgl)
  if (dev.last_ev == dev.LE_DEV_HS) rb_dhs = rb_dhs + 1;

// Report contents of SEQ s: byte n = s + 37 n
function [63:0] rb_bytes;
   input [7:0] s;
   integer     n;
   reg   [7:0] b;
   begin
      for (n = 0; n < 8; n = n + 1)
        begin
           b = s + 8'd37 * n[7:0];
           rb_bytes[8*n +: 8] = b;
        end
   end
endfunction

// Push n reports, one per ms, SEQ s0+1 onwards; short (3 bytes) every 16th when sh
task rb_pusher;
   input integer n;
   input         sh;
   integer       j;
   reg     [7:0] s;
   begin
      for (j = 1; j <= n; j = j + 1)
        begin
           s         = rb_s0 + j;
           rb_dat[s] = rb_bytes(s);
           rb_len[s] = (sh && (s[3:0] == 4'd5)) ? 7'd3 : 7'd8;
           rb_ok[s]  = 1'b1;
           dev.push_report(rb_len[s], rb_dat[s]);
           #(1.0e6);
        end
      rb_push_done = 1'b1;
   end
endtask

// Wait for the device to start a report packet (at most 5 ms): 0 on timeout
task rb_wait_tx;
   output integer got;
   integer        c0;
   begin
      c0    = dev.int_sent_cnt;
      rb_t0 = $realtime;
      while ((dev.int_sent_cnt == c0) && ($realtime - rb_t0 < 5.0e6)) #(1.0e3);
      got = (dev.int_sent_cnt != c0);
   end
endtask

// Four-read sequence with the SEQ retry; checks the consistent read
task rb_read_check;
   begin
      rb_i0 = 32'h0;
      rb_i1 = 32'hFFFF_FFFF;
      rb_i  = 0;
      while ((rb_i == 0) || (rb_i0[15:8] != rb_i1[15:8]))
        begin
           rdv(R_REPORT_INFO, rb_i0);
           rdv(R_REPORT0,     rb_w0);
           rdv(R_REPORT0 + 4, rb_w1);
           rdv(R_REPORT_INFO, rb_i1);
           if (rb_i0[15:8] != rb_i1[15:8]) rb_retry = rb_retry + 1;
           rb_i = rb_i + 1;
        end
      rb_reads = rb_reads + 1;
      rb_s = rb_i0[15:8];
      if (rb_i0 !== rb_i1)
        begin
           $display("ERROR: REPORT_INFO 0x%h then 0x%h with the same SEQ %t ns", rb_i0, rb_i1, $time);
           error = error + 1;
        end
      chk(((rb_s - rb_prev) & 8'hFF) < 8'd8, "SEQ never goes back");
      rb_prev = rb_s;
      if (rb_ok[rb_s])
        begin
           rb_m = (rb_len[rb_s] >= 7'd8) ? {64{1'b1}} : ((64'h1 << (8 * rb_len[rb_s])) - 64'h1);
           if ((rb_i0[6:0] != rb_len[rb_s]) || ((({rb_w1, rb_w0} ^ rb_dat[rb_s]) & rb_m) != 64'h0))
             begin
                $display("ERROR: SEQ %0d: LEN %0d REPORT %h, expected LEN %0d REPORT %h %t ns", rb_s, rb_i0[6:0],
                         {rb_w1, rb_w0} & rb_m, rb_len[rb_s], rb_dat[rb_s] & rb_m, $time);
                error = error + 1;
             end
        end
      else
        chk(rb_s == rb_s0[7:0], "a SEQ that no pushed report has");
   end
endtask

// One word read of REPORT[w]: four bytes of one pushed full-length report
task rb_word_check;
   input integer w;
   reg     [7:0] s;
   begin
      rdv(R_REPORT0 + 4 * w, rb_v);
      rb_reads = rb_reads + 1;
      s = rb_v[7:0] - 8'd37 * (4 * w);
      if (!rb_ok[s] || (rb_len[s] != 7'd8) || (((s - rb_s0[7:0]) & 8'hFF) > RB_N2) ||
          (rb_v !== rb_dat[s][32*w +: 32]))
        begin
           $display("ERROR: REPORT[%0d] 0x%h is not one report's bytes (SEQ %0d?) %t ns", w, rb_v, s, $time);
           error = error + 1;
        end
   end
endtask

initial
   begin
      wait_reset_done(5);
      for (rb_i = 0; rb_i < 256; rb_i = rb_i + 1)
        begin
           rb_ok[rb_i]  = 1'b0;
           rb_dat[rb_i] = 64'h0;
           rb_len[rb_i] = 7'd0;
        end
      rb_retry = 0;
      rb_reads = 0;
      enumerate(dev.P_KBD, C_EN | C_BOOT | C_IDLE0 | (32'd1 << 8), 600.0);
      wait_ms(3.0);
      rd(R_REPORT_INFO, 32'h0);
      for (rb_i = 2; rb_i < 16; rb_i = rb_i + 1)
        rd(R_REPORT0 + 4 * rb_i, 32'h0);

      // Four-read phase: back-to-back reads from each report packet's start
      // until past its commit
      rb_s0        = 0;
      rb_prev      = 8'd0;
      rb_push_done = 1'b0;
      fork
         rb_pusher(RB_N1, 1'b1);
         begin : rb_reader1
            for (rb_b = 0; rb_b < RB_N1; rb_b = rb_b + 1)
              begin
                 rb_wait_tx(rb_k);
                 if (rb_k == 0) disable rb_reader1;
                 rb_t0 = $realtime;
                 while ($realtime - rb_t0 < 250.0e3) rb_read_check;
              end
         end
      join
      wait_ms(5.0);
      rb_read_check;
      chk(rb_s == (RB_N1 % 256), "every pushed report committed once, in order");
      chk(dev.rf_cnt[1] == 0, "no report left in the device");
      $display("[%0t] four-read phase: %0d consistent reads, %0d retries", $time, rb_reads, rb_retry);
      chk(rb_retry > 0, "some reads saw a swap and were retried");

      // Single-word phase: full-length reports only
      rb_s0        = RB_N1;
      rb_push_done = 1'b0;
      rb_reads     = 0;
      fork
         rb_pusher(RB_N2, 1'b0);
         begin : rb_reader2
            for (rb_b = 0; rb_b < RB_N2; rb_b = rb_b + 1)
              begin
                 rb_wait_tx(rb_k);
                 if (rb_k == 0) disable rb_reader2;
                 rb_t0 = $realtime;
                 while ($realtime - rb_t0 < 250.0e3)
                   begin
                      rb_word_check(0);
                      rb_word_check(1);
                   end
              end
         end
      join
      wait_ms(5.0);
      read_report(rb_l, rb_s, rb_m);
      chk(rb_s == (RB_N1 + RB_N2) % 256, "every pushed report committed once, in order");
      $display("[%0t] single-word phase: %0d reads", $time, rb_reads);
      chk(!st_seen(S_BACKOFF), "no failure");

      // Detach: the port leaves RUN, REPORT_INFO and the window read 0. The
      // detach comes 100 us after a NAK, so no host packet is under way
      // (the model allows 10 us of host drive after a detach)
      rb_k  = rb_dhs;
      rb_t0 = $realtime;
      while ((rb_dhs == rb_k) && ($realtime - rb_t0 < 5.0e6)) #(1.0e3);
      chk(rb_dhs != rb_k, "a poll answered NAK before the detach");
      #(100.0e3);
      dev.detach;
      wait_state(S_DETACHED, 5.0);
      rd(R_REPORT_INFO, 32'h0);           // LEN 0: the window holds no report
      stimulus_done = 1;
   end
