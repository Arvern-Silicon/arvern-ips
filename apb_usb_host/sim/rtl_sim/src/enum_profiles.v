//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    enum_profiles
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : enum_profiles.v
// Module Description : Six device profiles enumerated one after the other,
//                      detached in between: DEV_ID / DEV_IF / DEV_EP from
//                      their descriptors and one report delivered each.
//                      Mouse (boot, wMaxPacketSize 4); gamepad (no boot
//                      subclass: no SET_PROTOCOL, DEV_IF.BOOT 0, its report
//                      7F 7F 00 80 80 0F 00 00); composite (the first HID
//                      interface, the second endpoint never polled); an
//                      alternate setting 1 interface first (skipped);
//                      wTotalLength a multiple of 8; bInterval 0 (taken as 1).
//
// Doc "Enumeration", "Polling", "Register map".
//----------------------------------------------------------------------------

reg  [7:0] pr_seq;
reg  [6:0] pr_len;
reg [63:0] pr_d;
integer    pr_n_proto = 0;            // SET_PROTOCOL SETUPs the device accepted
integer    pr_n_idle  = 0;            // SET_IDLE SETUPs the device accepted

always @(posedge dev.setup_tgl or negedge dev.setup_tgl)
  if (dev.cs_rt == 8'h21)
    begin
       if (dev.cs_rq == 8'h0B) pr_n_proto = pr_n_proto + 1;
       if (dev.cs_rq == 8'h0A) pr_n_idle  = pr_n_idle + 1;
    end

// DEV_IF / DEV_EP layouts (doc "Register map")
function [31:0] pr_if;
   input       boot;
   input [7:0] proto;
   input [7:0] sub;
   input [7:0] num;
   pr_if = {7'h0, boot, proto, sub, num};
endfunction

function [31:0] pr_ep;
   input [6:0] mps0;
   input [7:0] interval;
   input [6:0] mps;
   input [3:0] num;
   pr_ep = {1'b0, mps0, interval, 5'h0, mps, num};
endfunction

// Attach a profile, wait for RUN, check the device information and one report
task pr_case;
   input integer  profile;
   input   [31:0] id;
   input   [31:0] dif;
   input   [31:0] dep;
   input integer  rlen;
   input   [63:0] rdata;
   begin
      wr(R_IRQ_PEND, I_ALL);
      st_hist_clear;
      pr_n_proto = 0;
      pr_n_idle  = 0;
      dev.attach(profile);
      wait_state(S_RUN, 600.0);
      chk(!st_seen(S_BACKOFF) && !st_seen(S_UNSUPPORTED), "enumeration without failure");
      status_chk(S_RUN, E_NONE, 4'd0);
      rd(R_DEV_ID, id);
      rd(R_DEV_IF, dif);
      rd(R_DEV_EP, dep);
      irq_chk(I_READY, I_READY);
      chk(pr_n_idle >= 1, "SET_IDLE sent (CTRL.IDLE0 = 1)");
      read_report(pr_len, pr_seq, pr_d);
      dev.push_report(rlen, rdata);
      expect_report(pr_seq, rlen, rdata, 40.0);
      status_chk(S_RUN, E_NONE, 4'd0);
   end
endtask

task pr_detach;
   begin
      dev.detach;
      wait_state(S_DETACHED, 2.0);
      dev.flush_reports;
      wait_ms(2.0);
   end
endtask

initial
   begin
      wait_reset_done(5);
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0);
      wait_state(S_DETACHED, 1.0);
      wait_ms(2.0);

      // Mouse: boot subclass, protocol 2, EP1 IN, wMaxPacketSize 4, bInterval 10
      pr_case(dev.P_MOUSE, 32'h0002_1209, pr_if(1'b1, 8'd2, 8'd1, 8'd0), pr_ep(7'd8, 8'd10, 7'd4, 4'd1),
              4, 64'h0000_0000_00FB_0501);
      chk(pr_n_proto >= 1, "mouse: SET_PROTOCOL sent");
      chk(dev.hid_proto[0] == 0, "mouse: boot protocol set");
      pr_detach;

      // Gamepad: subclass 0, so no SET_PROTOCOL although CTRL.BOOT = 1
      pr_case(dev.P_GAMEPAD, 32'h0011_0079, pr_if(1'b0, 8'd0, 8'd0, 8'd0), pr_ep(7'd8, 8'd10, 7'd8, 4'd1),
              8, 64'h0000_0F80_8000_7F7F);
      chk(pr_n_proto == 0, "gamepad: no SET_PROTOCOL");
      chk(dev.hid_proto[0] == 1, "gamepad: still in report protocol");
      pr_detach;

      // Composite: keyboard interface 0 on EP1 selected, interface 1 (EP2)
      // ignored: a report queued on EP2 is never polled
      dev.load_profile(dev.P_COMPOSITE);
      dev.push_report_ep(2, 2, 64'h0000_0000_0000_00E9);
      pr_case(-1, 32'h0003_1209, pr_if(1'b1, 8'd1, 8'd1, 8'd0), pr_ep(7'd8, 8'd10, 7'd8, 4'd1),
              8, 64'h0000_0000_0004_0000);
      wait_ms(25.0);
      chk(dev.rf_cnt[2] == 1, "composite: EP2 of the second interface not polled");
      pr_detach;

      // Alternate setting 1 of interface 0 first (EP2, subclass 0): skipped,
      // the alternate setting 0 interface (boot keyboard, EP1) selected
      pr_case(dev.P_ALT_FIRST, 32'h0006_1209, pr_if(1'b1, 8'd1, 8'd1, 8'd0), pr_ep(7'd8, 8'd10, 7'd8, 4'd1),
              8, 64'h0000_0000_0005_0000);
      pr_detach;

      // wTotalLength 40, a multiple of 8: the configuration read ends with
      // wTotalLength bytes received
      pr_case(dev.P_TOTAL8, 32'h0007_1209, pr_if(1'b1, 8'd1, 8'd1, 8'd0), pr_ep(7'd8, 8'd10, 7'd8, 4'd1),
              8, 64'h0000_0000_0006_0000);
      pr_detach;

      // bInterval 0 (illegal): taken as 1, DEV_EP shows 1
      pr_case(dev.P_BINT0, 32'h000A_1209, pr_if(1'b1, 8'd1, 8'd1, 8'd0), pr_ep(7'd8, 8'd1, 7'd8, 4'd1),
              8, 64'h0000_0000_0007_0000);
      pr_detach;

      stimulus_done = 1;
   end
