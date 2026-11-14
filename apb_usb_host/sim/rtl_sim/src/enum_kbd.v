//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    enum_kbd
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : enum_kbd.v
// Module Description : A boot keyboard attached to an enabled port: the
//                      state sequence of the doc (DETACHED, DEBOUNCE, two
//                      bus resets around step 1, ENUM, RUN), the timer
//                      lengths, the device information registers, the
//                      boot protocol set, READY and STATE interrupts, then
//                      four reports read through the window with SEQ
//                      incrementing and REPORT on irq_o.
//
// Doc "States", "Bus timing", "Enumeration", "Polling", "Report buffer".
//----------------------------------------------------------------------------

integer    i;
reg [31:0] v;
reg  [7:0] seq;
reg  [6:0] len;
reg [63:0] d;
real       t;

initial
   begin
      wait_reset_done(5);
      wr(R_IRQ_EN, I_REPORT | I_READY);
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0);
      wait_state(S_DETACHED, 1.0);
      wait_ms(2.0);
      dev.attach(dev.P_KBD);
      wait_state(S_RUN, 600.0);

      // State sequence and timer lengths
      chk(st_count(S_RESET) == 2,    "two bus resets (step 2)");
      chk(st_count(S_RECOVERY) == 2, "two recoveries");
      chk(st_count(S_DEBOUNCE) == 1, "one debounce");
      chk(!st_seen(S_BACKOFF),       "no failure");
      chk_range(st_dur_last(S_DEBOUNCE), T_DEBOUNCE, T_DEBOUNCE + T_MS + T_LAT, "DEBOUNCE length");
      chk_range(st_dur_last(S_RESET),    T_RESET,    T_RESET + T_MS + T_LAT,    "RESET length");
      chk_range(st_dur_last(S_RECOVERY), T_RECOVERY, T_RECOVERY + T_MS + T_LAT, "RECOVERY length");

      // Device information
      status_chk(S_RUN, E_NONE, 4'd0);
      rd(R_DEV_ID, 32'h0001_1209);
      rd(R_DEV_IF, {7'h0, 1'b1, 8'd1, 8'd1, 8'd0});        // boot set, protocol 1, subclass 1, if 0
      rd(R_DEV_EP, {1'b0, 7'd8, 8'd10, 5'h00, 7'd8, 4'd1});
      chk(irq === 1'b1, "READY raises irq_o");
      irq_chk(I_READY | I_STATE, I_READY | I_STATE | I_FAIL | I_DETACH | I_REPORT);
      chk(irq === 1'b0, "irq_o low once READY is cleared");
      chk(dev.hid_proto[0] == 0, "the device is in boot protocol");
      chk(dev.hid_idle[0] == 0,  "the device idle rate is 0");

      // Reports
      read_report(len, seq, d);
      chk(seq == 8'd0, "no report yet");
      for (i = 0; i < 4; i = i + 1)
        begin
           dev.push_report(8, 64'h0000_0006_0500_0002 + i);
           expect_report(seq, 8, 64'h0000_0006_0500_0002 + i, 30.0);
           seq = seq + 8'd1;
           chk(irq === 1'b1, "REPORT raises irq_o");
           irq_chk(I_REPORT, I_REPORT);
        end

      // A short report
      dev.push_report(3, 64'h0000_0000_0001_0203);
      expect_report(seq, 3, 64'h0000_0000_0001_0203, 30.0);
      status_chk(S_RUN, E_NONE, 4'd0);
      stimulus_done = 1;
   end
