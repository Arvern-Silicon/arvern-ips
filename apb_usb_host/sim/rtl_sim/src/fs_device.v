//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    fs_device
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : fs_device.v
// Module Description : A full-speed device (D+ pull-up) with FS_EN = 0:
//                      DEBOUNCE then FS_DETECTED 100 to 101 ms after the
//                      attach, STATUS.FS_DEV = 1, LINE = 2'b10, no FAIL, the
//                      bus never driven; a disconnect returns to DETACHED
//                      with FS_DEV = 0. CMD.RESTART in FS_DETECTED is
//                      ignored: the device is never driven.
//
// Doc "States", "Line state, attachment and disconnect", "Transactions",
// "Attempts", "Register map".
//----------------------------------------------------------------------------

reg [31:0] fs_v;
real       fs_t;
reg        fs_watch = 1'b0;
integer    fs_drv   = 0;                   // host drives outside RESET while fs_watch
integer    fs_rst   = 0;                   // host drives inside RESET while fs_watch

always @(posedge usb_oe)
  if (fs_watch)
    begin
       #1;
       if (tb_state == S_RESET) fs_rst = fs_rst + 1;
       else                     fs_drv = fs_drv + 1;
    end

initial
   begin
      wait_reset_done(5);
      wr(R_CTRL, CTRL_RST | C_EN);
      wait_state(S_DETACHED, 1.0);
      wait_ms(1.0);
      fs_watch = 1'b1;

      // Attach: DEBOUNCE, then FS_DETECTED after 100 ms of full-speed J
      wr(R_IRQ_PEND, I_ALL);
      st_hist_clear;
      dev.attach(dev.P_FS);
      fs_t = $realtime;
      wait_state(S_DEBOUNCE, 1.0);
      wait_ms(1.0);
      rdv(R_STATUS, fs_v);
      chk(f_line(fs_v) == 2'b10,       "LINE = 2'b10 (D+ high) with a full-speed device");
      wait_state(S_FS_DETECTED, 110.0);
      chk_range($realtime - fs_t, T_DEBOUNCE, T_DEBOUNCE + T_MS + T_LAT, "FS_DETECTED after the debounce");
      chk(st_n == 2 && st_hist[0] == S_DEBOUNCE && st_hist[1] == S_FS_DETECTED, "DETACHED -> DEBOUNCE -> FS_DETECTED");
      wait_ms(20.0);
      rdv(R_STATUS, fs_v);
      chk(f_state(fs_v) == S_FS_DETECTED, "FS_DETECTED");
      chk(f_fs_dev(fs_v) == 1'b1,      "FS_DEV = 1 in FS_DETECTED");
      chk(f_line(fs_v) == 2'b10,       "LINE = 2'b10 in FS_DETECTED");
      chk(f_err(fs_v) == E_NONE && f_step(fs_v) == 4'd0, "no ERR / STEP for a full-speed device");
      // FAIL is BACKOFF / FAILED / UNSUPPORTED only; STATE did change
      irq_chk(I_STATE, I_STATE | I_FAIL | I_READY | I_DETACH | I_REPORT);
      // It waits there with the port released
      wait_ms(50.0);
      chk(tb_state == S_FS_DETECTED,   "FS_DETECTED waits for a line event");
      chk(fs_drv == 0 && fs_rst == 0,  "the host never drives a full-speed device");

      // Disconnect: DETACHED, FS_DEV back to 0, no DETACH (not in RUN)
      dev.detach;
      fs_t = $realtime;
      wait_state(S_DETACHED, 0.05);
      chk_range($realtime - fs_t, 2250.0, 2500.0 + 4.0 * PCLK_P, "disconnect detection (SE0 > 2.25 us)");
      rdv(R_STATUS, fs_v);
      chk(f_fs_dev(fs_v) == 1'b0,      "FS_DEV = 0 in DETACHED");
      chk(f_line(fs_v) == 2'b00,       "LINE = SE0 in DETACHED");
      irq_chk(I_STATE, I_STATE | I_FAIL | I_DETACH);

      // Again, then CMD.RESTART: ignored, the device is never driven
      dev.attach(dev.P_FS);
      wait_state(S_FS_DETECTED, 110.0);
      wait_ms(5.0);
      st_hist_clear;
      wr(R_IRQ_PEND, I_ALL);
      wr(R_CMD, K_RESTART);
      wait_ms(20.0);
      chk(st_n == 0,                   "RESTART in FS_DETECTED changes no state");
      status_chk(S_FS_DETECTED, E_NONE, 4'd0);
      irq_chk(32'h0, I_ALL);
      chk(fs_drv == 0 && fs_rst == 0,  "the host never drives a full-speed device");

      // Disconnect
      dev.detach;
      wait_state(S_DETACHED, 0.05);
      rdv(R_STATUS, fs_v);
      chk(f_fs_dev(fs_v) == 1'b0,      "FS_DEV = 0 in DETACHED");
      wait_ms(1.0);
      fs_watch = 1'b0;
      stimulus_done = 1;
   end
