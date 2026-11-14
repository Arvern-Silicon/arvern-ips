//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    enum_malformed
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : enum_malformed.v
// Module Description : Keyboard configuration descriptors edited before the
//                      attach. Malformed (ERR 6, step 5, a failure: BACKOFF
//                      with ATTEMPT 1 and IRQ_PEND.FAIL): a bLength of 0, a
//                      descriptor running past wTotalLength, a descriptor
//                      running past the 255 bytes requested. No usable HID
//                      interface (ERR 8, step 5, UNSUPPORTED with ATTEMPT 0):
//                      the only endpoint OUT, the endpoint bulk instead of
//                      interrupt, the interface beyond the 255 bytes
//                      requested. Each
//                      case ends with a detach.
//
// Doc "Enumeration", "Attempts", "States", "Register map".
//----------------------------------------------------------------------------

reg [31:0] ml_v;
integer    ml_k;

// Keyboard configuration layout (usb_ls_dev load_profile): configuration
// 0-8 (wTotalLength at 2-3), interface 9-17, HID 18-26, endpoint 27-33
// (bEndpointAddress at 29, bmAttributes at 30)

// Attach the loaded descriptors, expect a failure of step 5 with err:
// ERR 6 in BACKOFF, ERR 8 in UNSUPPORTED; then detach
task ml_case;
   input    [3:0] err;
   reg      [3:0] st;
   begin
      st = (err == E_MALFORMED) ? S_BACKOFF : S_UNSUPPORTED;
      wr(R_IRQ_PEND, I_ALL);
      st_hist_clear;
      dev.attach(-1);
      wait_state(st, 600.0);
      status_chk(st, err, 4'd5);
      rdv(R_STATUS, ml_v);
      chk(f_attempt(ml_v) == ((err == E_MALFORMED) ? 2'd1 : 2'd0), "ATTEMPT after the step-5 failure");
      irq_chk(I_FAIL, I_FAIL);
      chk(st_count(S_RESET) == 2, "the failure is at step 5, after the second bus reset");
      if (err != E_MALFORMED) chk(!st_seen(S_BACKOFF), "UNSUPPORTED: no BACKOFF");
      wait_ms(3.0);
      chk(tb_state === st, "still waiting");
      chk(usb_oe === 1'b0, "lines released");
      dev.detach;
      wait_state(S_DETACHED, 2.0);
      wait_ms(2.0);
   end
endtask

// Configuration of 9 header bytes with wTotalLength 288 followed by n
// skippable 6-byte class-specific descriptors (CS_INTERFACE 0x24)
task ml_long_cfg;
   input integer n;
   integer       b;
   begin
      dev.load_profile(dev.P_KBD);
      dev.desc_len(dev.R_CFG, 9);
      dev.desc_set(dev.R_CFG, 2, 8'h20);
      dev.desc_set(dev.R_CFG, 3, 8'h01);
      for (ml_k = 0; ml_k < n; ml_k = ml_k + 1)
        begin
           b = 9 + 6 * ml_k;
           dev.desc_set(dev.R_CFG, b,     6);
           dev.desc_set(dev.R_CFG, b + 1, 8'h24);
           dev.desc_set(dev.R_CFG, b + 2, 0);
           dev.desc_set(dev.R_CFG, b + 3, 0);
           dev.desc_set(dev.R_CFG, b + 4, 0);
           dev.desc_set(dev.R_CFG, b + 5, 0);
        end
   end
endtask

initial
   begin
      wait_reset_done(5);
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0);
      wait_state(S_DETACHED, 1.0);
      wait_ms(2.0);

      // bLength 0 (the HID descriptor), before the endpoint is found
      dev.load_profile(dev.P_KBD);
      dev.desc_set(dev.R_CFG, 18, 0);
      ml_case(E_MALFORMED);

      // wTotalLength 30: the endpoint descriptor (27-33) runs past it
      dev.load_profile(dev.P_KBD);
      dev.desc_set(dev.R_CFG, 2, 30);
      ml_case(E_MALFORMED);

      // 9 + 40 * 6 = 249 bytes of descriptors, then a 9-byte one at 249-257:
      // it runs past the 255 bytes requested (wTotalLength 288)
      ml_long_cfg(40);
      dev.desc_set(dev.R_CFG, 249, 9);
      dev.desc_set(dev.R_CFG, 250, 8'h24);
      for (ml_k = 251; ml_k < 256; ml_k = ml_k + 1) dev.desc_set(dev.R_CFG, ml_k, 0);
      ml_case(E_MALFORMED);

      // The interface's only endpoint is OUT (bEndpointAddress 0x01)
      dev.load_profile(dev.P_KBD);
      dev.desc_set(dev.R_CFG, 29, 8'h01);
      ml_case(E_NO_HID);

      // The endpoint is bulk (bmAttributes 2), not interrupt
      dev.load_profile(dev.P_KBD);
      dev.desc_set(dev.R_CFG, 30, 2);
      ml_case(E_NO_HID);

      // 9 + 41 * 6 = 255 bytes of skippable descriptors: the interface would
      // start at byte 255, beyond the 255 bytes requested
      ml_long_cfg(41);
      dev.desc_set(dev.R_CFG, 255, 9);
      ml_case(E_NO_HID);

      stimulus_done = 1;
   end
