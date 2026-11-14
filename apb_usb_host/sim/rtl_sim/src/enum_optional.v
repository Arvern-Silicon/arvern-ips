//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    enum_optional
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : enum_optional.v
// Module Description : Enumeration steps 7 (SET_PROTOCOL) and 8 (SET_IDLE)
//                      are optional, with a boot keyboard. SET_PROTOCOL
//                      STALLed: RUN, DEV_IF.BOOT 0, SET_IDLE still sent.
//                      CTRL.BOOT = 0: no SET_PROTOCOL, the device stays in
//                      report protocol. CTRL.IDLE0 = 0: no SET_IDLE. Three
//                      transaction errors on SET_PROTOCOL: the sequence
//                      continues, BOOT 0. SET_IDLE NAKed forever: the progress
//                      timeout ends step 8 and the port still reaches RUN and
//                      delivers reports. No case is a failure.
//
// Doc "Enumeration", "Transactions", "Register map" (CTRL, DEV_IF).
//----------------------------------------------------------------------------

integer    op_n_proto = 0;            // SET_PROTOCOL SETUPs the device accepted
integer    op_n_idle  = 0;            // SET_IDLE SETUPs the device accepted
reg  [7:0] op_seq;
reg  [6:0] op_len;
reg [63:0] op_d;

always @(posedge dev.setup_tgl or negedge dev.setup_tgl)
  if (dev.cs_rt == 8'h21)
    begin
       if (dev.cs_rq == 8'h0B) op_n_proto = op_n_proto + 1;
       if (dev.cs_rq == 8'h0A) op_n_idle  = op_n_idle + 1;
    end

// Run one enumeration (attach or CMD.RESTART) with ctrl, expect RUN without
// failure, then DEV_IF with its BOOT bit
task op_case;
   input          restart;
   input   [31:0] ctrl;
   input          boot;
   input     real ms;
   begin
      wr(R_CTRL, ctrl);
      wr(R_IRQ_PEND, I_ALL);
      st_hist_clear;
      op_n_proto = 0;
      op_n_idle  = 0;
      if (restart) wr(R_CMD, K_RESTART);
      else         dev.attach(-1);
      wait_state(S_RUN, ms);
      chk(!st_seen(S_BACKOFF) && !st_seen(S_FAILED), "optional steps: no failure");
      status_chk(S_RUN, E_NONE, 4'd0);
      rd(R_DEV_IF, {7'h0, boot, 8'd1, 8'd1, 8'd0});
      irq_chk(I_READY, I_READY | I_FAIL);
   end
endtask

initial
   begin
      wait_reset_done(5);
      dev.load_profile(dev.P_KBD);
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0);
      wait_state(S_DETACHED, 1.0);
      wait_ms(2.0);

      // A STALLed SET_PROTOCOL status stage ends that request (USB 2.0
      // 8.5.3.4); the model keeps it open and its STATUS checker would count
      // the next SETUP (SET_IDLE) or bus reset as abandoning it. The later
      // cases leave SET_PROTOCOL or SET_IDLE open the same way.
      dev.chk_enable(dev.C_STATUS, 0);

      // Step 7 STALLed: the sequence continues, BOOT stays 0
      dev.inject_fault(dev.F_STALL, dev.T_IN, 0, 8'h0B, -1, dev.ST_STATUS, 0, -1, 0);
      op_case(1'b0, C_EN | C_BOOT | C_IDLE0, 1'b0, 600.0);
      chk(op_n_proto >= 1, "SET_PROTOCOL sent");
      chk(dev.fr_hits[0] >= 1, "SET_PROTOCOL STALLed");
      chk(dev.hid_proto[0] == 1, "STALLed SET_PROTOCOL: report protocol");
      chk(op_n_idle >= 1, "SET_IDLE sent after the STALL");
      chk(dev.hid_idle[0] == 0, "SET_IDLE(0) applied");
      dev.clear_faults;

      // CTRL.BOOT = 0: no SET_PROTOCOL
      op_case(1'b1, C_EN | C_IDLE0, 1'b0, 400.0);
      chk(op_n_proto == 0, "CTRL.BOOT = 0: no SET_PROTOCOL");
      chk(dev.hid_proto[0] == 1, "CTRL.BOOT = 0: the device stays in report protocol");
      chk(op_n_idle >= 1, "SET_IDLE sent");
      chk(dev.hid_idle[0] == 0, "SET_IDLE(0) applied");

      // CTRL.IDLE0 = 0: no SET_IDLE; the bus reset restored the keyboard's
      // default idle rate (500 ms, 125 in 4 ms units: HID 1.11 7.2.4)
      op_case(1'b1, C_EN | C_BOOT, 1'b1, 400.0);
      chk(op_n_idle == 0, "CTRL.IDLE0 = 0: no SET_IDLE");
      chk(dev.hid_idle[0] == 125, "CTRL.IDLE0 = 0: idle rate unchanged");
      chk(dev.hid_proto[0] == 0, "boot protocol set");

      // Step 7: three silent SET_PROTOCOL status stages end the step
      dev.inject_fault(dev.F_SILENT, dev.T_IN, 0, 8'h0B, -1, dev.ST_STATUS, 0, 3, 0);
      op_case(1'b1, C_EN | C_BOOT | C_IDLE0, 1'b0, 400.0);
      chk(dev.fr_hits[0] == 3, "three transaction errors on SET_PROTOCOL");
      chk(dev.hid_proto[0] == 1, "failed SET_PROTOCOL: report protocol");
      chk(op_n_idle >= 1, "SET_IDLE sent after the failed step 7");
      chk(dev.hid_idle[0] == 0, "SET_IDLE(0) applied");
      dev.clear_faults;

      // Step 8: SET_IDLE status stage NAKed forever, ended by the progress
      // timeout; RUN is still reached and polling works
      dev.inject_fault(dev.F_NAK, dev.T_IN, 0, 8'h0A, -1, dev.ST_STATUS, 0, -1, 0);
      op_case(1'b1, C_EN | C_BOOT | C_IDLE0, 1'b1, 900.0);
      chk(st_dur_last(S_ENUM) >= 500.0 * T_MS, "step 8 ended by the 500 ms progress timeout");
      chk(dev.hid_idle[0] == 125, "SET_IDLE never completed");
      read_report(op_len, op_seq, op_d);
      dev.push_report(8, 64'h0000_0000_0004_0000);
      expect_report(op_seq, 8, 64'h0000_0000_0004_0000, 40.0);
      status_chk(S_RUN, E_NONE, 4'd0);

      stimulus_done = 1;
   end
