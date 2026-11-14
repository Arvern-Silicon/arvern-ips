//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    reset_in_operation
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : reset_in_operation.v
// Module Description : A system reset (presetn pulsed by the stimulus) during
//                      the first bus reset, then in RUN: the
//                      lines are released at once, every register is back to
//                      its reset value, the port is OFF and the clock request
//                      low; the device, still attached and left configured by
//                      the "previous run", is reset and enumerated again like
//                      a new one when the port is enabled, and delivers a
//                      report.
//
// Doc introduction ("comes out of reset with the bus lines released"),
// "Ports", "Register map", "Clock request", "States", "Enumeration".
//----------------------------------------------------------------------------

integer    ro_i;
reg [31:0] ro_v;
reg  [7:0] ro_seq;
reg  [6:0] ro_len;
reg [63:0] ro_dat;

task ro_quiet;
   begin
      while (!((usb_oe === 1'b0) && (dev.drv_en === 1'b0) && ($realtime - tb_act_t >= 100.0e3)))
        #(10.0e3);
   end
endtask

// Registers away from their reset values, so the reset is visible
task ro_dirty;
   begin
      wr(R_IRQ_EN, I_ALL);
      wr(R_SETUP0, 32'hA5A5_5A5A);
      wr(R_SETUP1, 32'h1234_5678);
      wr(R_XDATA0, 32'hDEAD_BEEF);
      wr(R_XDATA0 + 4, 32'hCAFE_F00D);
      wr(R_XFER, 32'h55);
      wr(R_MDELEG, (MDELEG_RST == 9'h000) ? 32'h105 : 32'h000);
   end
endtask

// Every register at its reset value (STATUS.LINE excluded: the device is
// attached, and the lines show as sampled by the access)
task ro_chk_reset;
   reg [31:0] e;
   integer    a;
   begin
      chk(usb_oe === 1'b0 && usb_dp_o === 1'b0 && usb_dm_o === 1'b0, "lines released after the reset");
      chk(irq === 1'b0, "irq_o low after the reset");
      chk(tb_state === S_OFF, "port OFF after the reset");
      @(negedge free_clk);
      #2;
      chk(pclk_en === 1'b0, "no clock request after the reset");
      for (a = 0; a < 32'h100; a = a + 4)
        begin
           case (a)
             R_INFO:   e = INFO_VALUE;
             R_CTRL:   e = CTRL_RST;
             R_MDELEG: e = MDELEG_RST_WORD;
             default:  e = 32'h0;
           endcase
           if (a == R_STATUS)
             begin
                rdv(R_STATUS, ro_v);
                chk32(ro_v & ~32'h30, 32'h0, "STATUS after the reset (LINE masked)");
             end
           else
             apb_read(1, MACHINE, a, e, SZ_W, 1'b1, OK);
        end
   end
endtask

// presetn low for 20 cycles, aligned to free_clk (the synchronous-reset build
// samples it on the clock the reset generator keeps running); the lines are
// released at once with the asynchronous reset, at the next edge otherwise
task ro_sys_reset;
   begin
      @(posedge free_clk);
      #1;
      presetn = 1'b0;
      if (ASYNC_RST_EN != 0)
        begin
           #1;
           chk(usb_oe === 1'b0, "lines released as soon as presetn falls");
        end
      @(posedge free_clk);
      #1;
      chk(usb_oe === 1'b0 && usb_dp_o === 1'b0 && usb_dm_o === 1'b0, "lines released during the reset");
      repeat (19) @(posedge free_clk);
      #1;
      presetn = 1'b1;
      wait_reset_done(5);
   end
endtask

// Enable with the device still attached: debounce, two bus resets, ENUM, RUN,
// address 1 again, then a report
task ro_enum_again;
   begin
      st_hist_clear;
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0);
      wait_state(S_RUN, 600.0);
      chk(st_count(S_DEBOUNCE) == 1, "one debounce");
      chk(st_count(S_RESET) == 2,    "two bus resets (step 2)");
      chk(!st_seen(S_BACKOFF),       "no failure");
      chk(dev_address == 7'd1, "device at address 1 again");
      chk(dev_configured === 1'b1, "device configured again");
      status_chk(S_RUN, E_NONE, 4'd0);
      rd(R_DEV_ID, 32'h0001_1209);
      if (DIAG_EN != 0) rd(R_DIAG1, 32'h2);
      read_report(ro_len, ro_seq, ro_dat);
      chk(ro_seq == 8'd0, "REPORT_INFO.SEQ from 0 after the reset");
      dev.push_report(8, 64'h1122_3344_5566_7788);
      expect_report(ro_seq, 8, 64'h1122_3344_5566_7788, 50.0);
   end
endtask

initial
   begin
      wait_reset_done(5);

      // System reset during the first bus reset: the bus reset is cut short by
      // the host's own reset, which is legal here, so the device's reset-length
      // check is off until the release has been seen
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0);
      dev.attach(dev.P_KBD);
      wait_state(S_RESET, 150.0);
      wait_ms(5.0);
      chk(usb_oe === 1'b1, "bus reset drives the lines");
      ro_dirty;
      dev.chk_enable(dev.C_RESET, 0);
      ro_sys_reset;
      wait_ms(0.1);
      dev.chk_enable(dev.C_RESET, 1);
      ro_chk_reset;
      wait_ms(1.0);
      chk(tb_state === S_OFF && usb_oe === 1'b0, "port stays OFF");

      // Enable: debounce and a full enumeration, then a report
      ro_enum_again;

      // System reset in RUN, between two bus transactions: the device stays
      // configured at address 1
      ro_dirty;
      ro_quiet;
      ro_sys_reset;
      ro_chk_reset;
      chk(dev_configured === 1'b1 && dev_address == 7'd1,
          "device still attached and configured after the host reset");
      wait_ms(1.0);
      chk(tb_state === S_OFF && usb_oe === 1'b0, "port stays OFF");

      // Enable: the configured device is reset and enumerated again like a new one
      ro_enum_again;

      stimulus_done = 1;
   end
