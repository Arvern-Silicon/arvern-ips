//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    detach_attach2
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : detach_attach2.v
// Module Description : Repeated detach / attach: three cycles with a
//                      keyboard, a mouse and a gamepad, each debounced,
//                      enumerated (two bus resets, its own DEV_ID), READY,
//                      a report from SEQ 0, then a disconnect in RUN with
//                      DETACH, REPORT_INFO cleared and DEV_ID kept until the
//                      next enumeration starts.
//
// Doc "States", "Line state, attachment and disconnect", "Register map".
//----------------------------------------------------------------------------

integer    da_c;
reg [31:0] da_id;
reg [63:0] da_rpt;
integer    da_len;

// A quiet bus point: after a keep-alive (a host drive shorter than 5 us),
// host and device both silent for 40 us. For the states with one short
// transaction per frame (RECOVERY, ENUM held by a NAK, RUN).
task da_quiet;
   input real ms;
   real       t0;
   reg        ok;
   integer    n;
   integer    k;
   begin : q
      ok = 1'b0;
      fork
         begin : q_ev
            while (!ok)
              begin
                 @(posedge usb_oe);
                 t0 = $realtime;
                 @(negedge usb_oe);
                 if ($realtime - t0 < 5000.0) ok = 1'b1;
              end
            n = 0;
            while (n < 40)
              begin
                 #(1000.0);
                 n = ((usb_oe === 1'b0) && (dev.drv_en === 1'b0)) ? n + 1 : 0;
              end
            disable q_to;
         end
         begin : q_to
            for (k = 0; k < ms * 100.0; k = k + 1)
              #(10.0e3);
            ok = 1'b0;
            disable q_ev;
         end
      join
      if (!ok)
        begin
           $display("ERROR: no keep-alive within %0.1f ms (STATE %0s) %t ns", ms, st_name(tb_state), $time);
           error = error + 1;
        end
   end
endtask

// Disconnect at a quiet point with the host released: DETACHED once the SE0
// has lasted more than 2.25 us (TDDIS 2 to 2.5 us; 4 pclk of synchroniser
// and register latency allowed)
task da_detach_quiet;
   real t0;
   begin
      da_quiet(2.0);
      dev.detach;
      t0 = $realtime;
      wait_state(S_DETACHED, 0.05);
      chk_range($realtime - t0, 2250.0, 2500.0 + 4.0 * PCLK_P, "disconnect detection (SE0 > 2.25 us)");
   end
endtask

initial
   begin
      wait_reset_done(5);
      wr(R_CTRL, CTRL_RST | C_EN);
      wait_state(S_DETACHED, 1.0);
      wait_ms(1.0);
      for (da_c = 0; da_c < 3; da_c = da_c + 1)
        begin
           case (da_c)
             0:       begin da_id = 32'h0001_1209; da_len = 8; da_rpt = 64'h0000_0004_0000_0001; end
             1:       begin da_id = 32'h0002_1209; da_len = 4; da_rpt = 64'h0000_0000_00FE_0201; end
             default: begin da_id = 32'h0011_0079; da_len = 8; da_rpt = 64'h0000_0F80_8000_007F; end
           endcase
           st_hist_clear;
           wr(R_IRQ_PEND, I_ALL);
           dev.attach((da_c == 0) ? dev.P_KBD : (da_c == 1) ? dev.P_MOUSE : dev.P_GAMEPAD);
           wait_state(S_RUN, 400.0);
           chk(st_count(S_DEBOUNCE) == 1 && st_count(S_RESET) == 2, "debounce and two bus resets per attach");
           chk(st_count(S_DETACHED) == 0, "the host's own SE0 is not a disconnect");
           status_chk(S_RUN, E_NONE, 4'd0);
           rd(R_DEV_ID, da_id);
           irq_chk(I_READY, I_READY | I_DETACH | I_FAIL);
           dev.push_report(da_len, da_rpt);
           expect_report(8'd0, da_len, da_rpt, 30.0);
           wait_ms(5.0);
           wr(R_IRQ_PEND, I_ALL);
           da_detach_quiet;
           irq_chk(I_DETACH, I_DETACH | I_READY | I_FAIL);
           rd(R_REPORT_INFO, 32'h0);
           rd(R_DEV_ID, da_id);
           wait_ms(5.0);
        end
      stimulus_done = 1;
   end
