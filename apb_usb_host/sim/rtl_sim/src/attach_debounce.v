//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    attach_debounce
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : attach_debounce.v
// Module Description : The attach debounce restarts on any line change.
//                      STATUS.LINE reads {D+, D-}: SE0 on an empty port,
//                      low-speed J with the device attached (OFF and
//                      DEBOUNCE). An attach removed before 100 ms goes
//                      DEBOUNCE -> DETACHED and the bus is never driven;
//                      after several short attach / detach bounces and a
//                      1 us SE0 glitch, the bus reset starts 100 to 101 ms
//                      after the last attach, and the device enumerates.
//
// Doc "States", "Line state, attachment and disconnect", "Bus timing".
//----------------------------------------------------------------------------

integer    ad_i;
reg [31:0] ad_v;
real       ad_t;
reg        ad_watch = 1'b0;
integer    ad_drv   = 0;                   // host drives outside RESET while ad_watch

always @(posedge usb_oe)
  if (ad_watch)
    begin
       #1;
       if (tb_state != S_RESET) ad_drv = ad_drv + 1;
    end

// Three STATUS reads: in OFF the synchronisers only move on the edges an
// access requests (doc "Clock request"), the last read is settled
task ad_status3;
   output [31:0] v;
   begin
      rdv(R_STATUS, v);
      rdv(R_STATUS, v);
      rdv(R_STATUS, v);
   end
endtask

initial
   begin
      wait_reset_done(5);

      // OFF: LINE shows the lines as sampled on the edges of an access
      dev.attach(dev.P_KBD);
      #(10.0e3);
      ad_status3(ad_v);
      chk(f_state(ad_v) == S_OFF,  "OFF while CTRL.EN = 0");
      chk(f_line(ad_v) == 2'b01,   "LINE = J (D- high) in OFF with a low-speed device");
      chk(usb_oe === 1'b0,         "lines released in OFF");
      dev.detach;
      #(10.0e3);
      ad_status3(ad_v);
      chk(f_line(ad_v) == 2'b00,   "LINE = SE0 in OFF with nothing attached");

      // DETACHED, nothing attached: SE0
      ad_watch = 1'b1;
      wr(R_CTRL, CTRL_RST | C_EN);
      wait_state(S_DETACHED, 1.0);
      wait_ms(2.0);
      rdv(R_STATUS, ad_v);
      chk(f_state(ad_v) == S_DETACHED, "DETACHED with nothing attached");
      chk(f_line(ad_v) == 2'b00,       "LINE = SE0 in DETACHED");
      chk(f_fs_dev(ad_v) == 1'b0,      "FS_DEV = 0 in DETACHED");

      // An attach removed after 50 ms: DEBOUNCE -> DETACHED, no reset.
      // DETACHED leaves at once on a J, so the low-speed J is read in DEBOUNCE.
      st_hist_clear;
      dev.attach(-1);
      wait_state(S_DEBOUNCE, 1.0);
      wait_ms(1.0);
      rdv(R_STATUS, ad_v);
      chk(f_state(ad_v) == S_DEBOUNCE, "DEBOUNCE on a low-speed J");
      chk(f_line(ad_v) == 2'b01,       "LINE = J (D- high) with a low-speed device");
      chk(f_fs_dev(ad_v) == 1'b0,      "FS_DEV = 0 with a low-speed device");
      wait_ms(49.0);
      dev.detach;
      wait_state(S_DETACHED, 1.0);
      chk(st_hist[st_n - 1] == S_DETACHED && st_hist[st_n - 2] == S_DEBOUNCE, "DEBOUNCE -> DETACHED on the detach");
      // Past the 100 ms of the abandoned debounce: still DETACHED, no reset
      wait_ms(70.0);
      chk(tb_state == S_DETACHED,      "still DETACHED after the abandoned debounce");
      chk(!st_seen(S_RESET),           "no bus reset for an attach shorter than 100 ms");
      chk(ad_drv == 0,                 "the host never drives during an abandoned debounce");
      rdv(R_STATUS, ad_v);
      chk(f_line(ad_v) == 2'b00,       "LINE = SE0 after the detach");

      // Bounces of a few ms, then a 1 us SE0 glitch 60 ms into a debounce,
      // then a stable attach: the debounce restarts each time
      st_hist_clear;
      for (ad_i = 0; ad_i < 4; ad_i = ad_i + 1)
        begin
           dev.attach(-1);
           wait_ms(3.0 + ad_i);
           dev.detach;
           wait_ms(2.0);
           chk(tb_state == S_DETACHED, "DETACHED after a bounce");
        end
      dev.attach(-1);
      wait_ms(60.0);
      dev.detach;
      #(1000.0);
      dev.attach(-1);
      ad_t = $realtime;
      wait_state(S_RESET, 110.0);
      chk_range($realtime - ad_t, T_DEBOUNCE, T_DEBOUNCE + T_MS + T_LAT, "RESET start after the last attach");
      chk(st_count(S_DEBOUNCE) == 6,   "one DEBOUNCE per attach (4 bounces, the glitch, the last)");
      chk(st_count(S_DETACHED) == 5,   "DETACHED on every line change in DEBOUNCE, the 1 us glitch included");
      chk(ad_drv == 0,                 "the host drives first at the bus reset");
      ad_watch = 1'b0;

      // The stable attach enumerates
      wait_state(S_RECOVERY, 62.0);
      chk_range(st_dur_last(S_RESET), T_RESET, T_RESET + T_MS + T_LAT, "RESET length");
      wait_state(S_RUN, 300.0);
      status_chk(S_RUN, E_NONE, 4'd0);
      rd(R_DEV_ID, 32'h0001_1209);
      stimulus_done = 1;
   end
