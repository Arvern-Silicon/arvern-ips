//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    poll_rate
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : poll_rate.v
// Module Description : The poll interval. A keyboard in repeat mode answers
//                      every IN with a report, so each poll is one ACK seen
//                      by the device and one REPORT_INFO.SEQ increment.
//                      CTRL.POLL_MS = 0 polls every bInterval (10 ms), then
//                      POLL_MS = 1 (300 polls, SEQ wraps 255 -> 0), 3, 255
//                      and back to 0, each written while the port runs: the
//                      poll after the write comes within the longer of the
//                      two intervals, the following ones at the new one.
//
// Doc "Polling", "Register map" (CTRL.POLL_MS, REPORT_INFO), "Bus timing".
//----------------------------------------------------------------------------

integer    pr_n = 0;                    // polls acknowledged (device ACK count changes)
real       pr_t [0:2047];               // time of each
reg  [7:0] pr_seq;                      // SEQ after the last checked poll
reg        pr_wrap;                     // SEQ seen going 255 -> 0
reg [31:0] pr_ctrl;                     // CTRL without POLL_MS
reg [31:0] pr_v;
integer    pr_bint;
integer    pr_cur;                      // POLL_MS in effect (0 = bInterval)
integer    pr_i;

always @(posedge dev.ack_tgl or negedge dev.ack_tgl)
  if (tb_rst_done === 1'b1)
    begin
       if (pr_n < 2048) pr_t[pr_n] = $realtime;
       pr_n = pr_n + 1;
    end

// Wait for the next acknowledged poll (at most ms); idx = its index, -1 on timeout
task pr_wait_poll;
   input  real    ms;
   output integer idx;
   integer        n0;
   reg            to;
   real           w;
   begin
      n0 = pr_n;
      w  = 0.0;
      while ((pr_n == n0) && (w < ms * T_MS))
        begin
           #(10.0e3);
           w = w + 10.0e3;
        end
      to = (pr_n == n0);
      if (to)
        begin
           $display("ERROR: no poll within %0.1f ms %t ns", ms, $time);
           error = error + 1;
           idx = -1;
        end
      else
        idx = n0;
   end
endtask

// After a poll: the report is committed, SEQ increments by one, LEN is 8
task pr_seq_check;
   begin
      #(200.0e3);
      rdv(R_REPORT_INFO, pr_v);
      if (pr_v[15:8] != pr_seq + 8'd1)
        begin
           $display("ERROR: REPORT_INFO.SEQ %0d after a poll, expected %0d %t ns", pr_v[15:8], pr_seq + 8'd1, $time);
           error = error + 1;
        end
      chk(pr_v[6:0] == 7'd8, "REPORT_INFO.LEN of the repeated report");
      if ((pr_seq == 8'd255) && (pr_v[15:8] == 8'd0)) pr_wrap = 1'b1;
      pr_seq = pr_v[15:8];
   end
endtask

// Effective interval of a POLL_MS value
function integer pr_ms;
   input integer pm;
   pr_ms = (pm == 0) ? pr_bint : pm;
endfunction

// k intervals at POLL_MS pm, from the last checked poll
task pr_measure;
   input integer pm;
   input integer k;
   integer       j, a, b;
   real          ex;
   begin
      ex = pr_ms(pm) * T_MS;
      a  = pr_n - 1;
      for (j = 0; j < k; j = j + 1)
        begin
           pr_wait_poll(pr_ms(pm) + 2.0, b);
           if (b >= 0)
             begin
                if ((a >= 0) && (a < 2048) && (b < 2048))
                  chk_range(pr_t[b] - pr_t[a], ex - 0.5 * T_MS, ex + 0.5 * T_MS, "poll interval");
                pr_seq_check;
             end
           a = b;
        end
   end
endtask

// Write POLL_MS while running, 200 us after a poll: the next poll comes no
// earlier than the shorter and no later than the longer interval (+1 frame),
// then pr_measure checks the new interval
task pr_switch;
   input integer pm;
   integer       a, b, lo, hi;
   begin
      lo = (pr_ms(pm) < pr_ms(pr_cur)) ? pr_ms(pm) : pr_ms(pr_cur);
      hi = (pr_ms(pm) > pr_ms(pr_cur)) ? pr_ms(pm) : pr_ms(pr_cur);
      a  = pr_n - 1;
      wr(R_CTRL, pr_ctrl | (pm << 8));
      rd(R_CTRL, pr_ctrl | (pm << 8));
      pr_wait_poll(hi + 2.0, b);
      if ((b >= 0) && (a >= 0) && (a < 2048) && (b < 2048))
        chk_range(pr_t[b] - pr_t[a], (lo - 0.5) * T_MS, (hi + 1.5) * T_MS, "first poll after a POLL_MS write");
      if (b >= 0) pr_seq_check;
      pr_cur = pm;
   end
endtask

initial
   begin
      wait_reset_done(5);
      pr_seq  = 8'd0;
      pr_wrap = 1'b0;
      pr_cur  = 0;
      pr_bint = 10;
      pr_ctrl = C_EN | C_BOOT | C_IDLE0;
      dev.set_repeat_last(1);
      enumerate(dev.P_KBD, pr_ctrl, 600.0);
      rdv(R_DEV_EP, pr_v);
      chk(pr_v[23:16] == 8'd10, "DEV_EP.bInterval of the keyboard profile");
      pr_bint = pr_v[23:16];
      rd(R_CTRL, pr_ctrl);

      // POLL_MS = 0: every bInterval. The first poll may already be past:
      // the SEQ after the next one is the base
      pr_wait_poll(20.0, pr_i);
      #(200.0e3);
      rdv(R_REPORT_INFO, pr_v);
      chk(pr_v[15:8] != 8'd0, "a report committed per poll");
      pr_seq = pr_v[15:8];
      pr_measure(0, 8);

      // POLL_MS = 1: every frame; 300 polls take SEQ through 255 -> 0
      pr_switch(1);
      pr_measure(1, 300);
      chk(pr_wrap, "REPORT_INFO.SEQ wraps from 255 to 0");

      // POLL_MS = 3, 255, then back to bInterval
      pr_switch(3);
      pr_measure(3, 8);
      pr_switch(255);
      pr_measure(255, 2);
      pr_switch(0);
      pr_measure(0, 3);

      chk(!st_seen(S_BACKOFF), "no failure while polling");
      status_chk(S_RUN, E_NONE, 4'd0);
      stimulus_done = 1;
   end
