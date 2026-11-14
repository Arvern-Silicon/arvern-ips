//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    enum_unsupported
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : enum_unsupported.v
// Module Description : Devices the port does not support end in UNSUPPORTED
//                      on their first attempt: a hub (ERR 7, step 1), a
//                      vendor device without a HID interface (ERR 8, step 5),
//                      wMaxPacketSize 0 and 16 (ERR 9, step 5),
//                      bMaxPacketSize0 16 (ERR 9, step 1). Each: IRQ_PEND.FAIL,
//                      no BACKOFF and ATTEMPT 0 (not a failure that retries),
//                      the lines released while the port waits for the
//                      detach, ERR / STEP surviving DETACHED. Then
//                      wMaxPacketSize 0x0808: bits [15:11] ignored, RUN with
//                      DEV_EP showing 8.
//
// Doc "States", "Attempts", "Enumeration", "Register map".
//----------------------------------------------------------------------------

reg [31:0] un_v;
integer    un_oe_hits = 0;            // host drives seen in UNSUPPORTED

always @(posedge usb_oe)
  begin
     #1;
     if (tb_state === S_UNSUPPORTED) un_oe_hits = un_oe_hits + 1;
  end

// Attach the loaded descriptors and expect UNSUPPORTED with err / step;
// nresets: bus resets before the decision (1 at step 1, 2 at step 5)
task un_case;
   input    [3:0] err;
   input    [3:0] step;
   input integer  nresets;
   begin
      wr(R_IRQ_PEND, I_ALL);
      st_hist_clear;
      un_oe_hits = 0;
      dev.attach(-1);
      wait_state(S_UNSUPPORTED, 600.0);
      status_chk(S_UNSUPPORTED, err, step);
      rdv(R_STATUS, un_v);
      chk(f_attempt(un_v) == 2'd0, "UNSUPPORTED consumes no attempt");
      irq_chk(I_FAIL, I_FAIL);
      chk(!st_seen(S_BACKOFF), "no BACKOFF");
      chk(st_count(S_RESET) == nresets, "bus resets before UNSUPPORTED");
      // Waits for the disconnect, lines released
      wait_ms(20.0);
      status_chk(S_UNSUPPORTED, err, step);
      chk(un_oe_hits == 0, "lines released in UNSUPPORTED");
      chk(dev_suspended === 1'b1, "no keep-alive in UNSUPPORTED: the device suspends");
      dev.detach;
      wait_state(S_DETACHED, 2.0);
      status_chk(S_DETACHED, err, step);
      wait_ms(2.0);
   end
endtask

initial
   begin
      wait_reset_done(5);
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0);
      wait_state(S_DETACHED, 1.0);
      wait_ms(2.0);

      // Hub: bDeviceClass 9 in the step-1 answer
      dev.load_profile(dev.P_HUB);
      un_case(E_HUB, 4'd1, 1);

      // Vendor-specific device: no HID interface in the configuration
      dev.load_profile(dev.P_VENDOR);
      un_case(E_NO_HID, 4'd5, 2);

      // Interrupt IN endpoint with wMaxPacketSize 0, then 16
      dev.load_profile(dev.P_MPS0);
      un_case(E_MPS, 4'd5, 2);
      dev.load_profile(dev.P_MPS_BIG);
      un_case(E_MPS, 4'd5, 2);

      // bMaxPacketSize0 16 (device descriptor byte 7)
      dev.load_profile(dev.P_KBD);
      dev.desc_set(dev.R_DEV, 7, 16);
      un_case(E_MPS, 4'd1, 1);

      // wMaxPacketSize 0x0808 (configuration bytes 31-32 of the keyboard):
      // bits [15:11] ignored, the endpoint is usable with 8 bytes
      dev.load_profile(dev.P_KBD);
      dev.desc_set(dev.R_CFG, 32, 8'h08);
      wr(R_IRQ_PEND, I_ALL);
      st_hist_clear;
      dev.attach(-1);
      wait_state(S_RUN, 600.0);
      chk(!st_seen(S_BACKOFF), "wMaxPacketSize 0x0808: no failure");
      status_chk(S_RUN, E_NONE, 4'd0);
      rd(R_DEV_EP, {1'b0, 7'd8, 8'd10, 5'h00, 7'd8, 4'd1});
      stimulus_done = 1;
   end
