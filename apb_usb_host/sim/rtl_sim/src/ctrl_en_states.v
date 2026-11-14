//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ctrl_en_states
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ctrl_en_states.v
// Module Description : CTRL.EN = 0 in the early states: DETACHED, DEBOUNCE,
//                      RESET, RECOVERY, ENUM at step 1 and ENUM at a later
//                      step (after SET_CONFIGURATION). Each time: OFF, lines
//                      released and quiet, ERR / STEP / DEV_ID / DEV_IF /
//                      DEV_EP / REPORT_INFO / REPORT clear, the clock
//                      request low once OFF; EN = 1 again restarts from
//                      DETACHED (DEBOUNCE with the device attached, ATTEMPT
//                      0, a full 100 ms debounce). The device then enumerates.
//                      ctrl_en_states2 covers the later states.
//
// Doc "States", "Attempts", "Bus timing", "Clock request", "Register map".
//----------------------------------------------------------------------------

reg [31:0] ce_v;
reg        ce_watch = 1'b0;
integer    ce_drv   = 0;                   // host drives while ce_watch

always @(posedge usb_oe)
  if (ce_watch) ce_drv = ce_drv + 1;

// A quiet bus point: after a keep-alive (a host drive shorter than 5 us),
// host and device both silent for 40 us. For the states with one short
// transaction per frame (RECOVERY, ENUM held by a NAK, RUN).
task ce_quiet;
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

// CTRL.EN = 0, the checks of OFF, then CTRL.EN = 1 again
task ce_off;
   input attached;                          // the device stays attached: EN = 1 leads on to DEBOUNCE
   begin
      wr(R_CTRL, CTRL_RST);
      // The doc gives no bound on reaching OFF; 20 us is a few bit times
      wait_state(S_OFF, 0.02);
      #(3.0 * PCLK_P);                       // the pad drivers are flops: released on the next edge
      chk(usb_oe === 1'b0,             "lines released in OFF");
      status_chk(S_OFF, E_NONE, 4'd0);
      rd(R_DEV_ID,      32'h0);
      rd(R_DEV_IF,      32'h0);
      rd(R_DEV_EP,      32'h0);
      rd(R_REPORT_INFO, 32'h0);           // LEN 0: the window holds no report
      repeat (4) @(negedge free_clk);
      chk(pclk_en === 1'b0,            "no clock request once OFF with the bus idle");
      // OFF holds: nothing driven, no state change
      ce_drv   = 0;
      ce_watch = 1'b1;
      st_hist_clear;
      wait_ms(2.0);
      chk(tb_state == S_OFF && st_n == 0, "OFF holds while CTRL.EN = 0");
      chk(ce_drv == 0,                 "nothing driven in OFF");
      ce_watch = 1'b0;
      // EN = 1: DETACHED first
      wr(R_CTRL, CTRL_RST | C_EN);
      if (attached)
        begin
           wait_state(S_DEBOUNCE, 1.0);
           chk(st_hist[0] == S_DETACHED && st_hist[1] == S_DEBOUNCE, "EN = 1: OFF -> DETACHED -> DEBOUNCE");
           rdv(R_STATUS, ce_v);
           chk(f_attempt(ce_v) == 2'd0, "ATTEMPT = 0 in DEBOUNCE");
        end
      else
        begin
           wait_state(S_DETACHED, 1.0);
           wait_ms(1.0);
           chk(tb_state == S_DETACHED,  "EN = 1: OFF -> DETACHED");
        end
   end
endtask

initial
   begin
      wait_reset_done(5);
      wr(R_CTRL, CTRL_RST | C_EN);
      wait_state(S_DETACHED, 1.0);
      wait_ms(1.0);

      // DETACHED
      ce_off(1'b0);

      // DEBOUNCE
      dev.attach(dev.P_KBD);
      wait_state(S_DEBOUNCE, 1.0);
      wait_ms(20.0);
      ce_off(1'b1);

      // RESET, after a full debounce from the re-enable
      wait_state(S_RESET, 102.0);
      chk_range(st_dur_last(S_DEBOUNCE), T_DEBOUNCE, T_DEBOUNCE + T_MS + T_LAT, "DEBOUNCE length after EN = 1");
      wait_ms(20.0);
      // Software cuts the bus reset short: the model's 50 ms minimum does not
      // apply to a reset abandoned by CTRL.EN = 0
      dev.chk_enable(dev.C_RESET, 0);
      ce_off(1'b1);
      dev.chk_enable(dev.C_RESET, 1);

      // RECOVERY
      wait_state(S_RECOVERY, 200.0);
      chk_range(st_dur_last(S_RESET), T_RESET, T_RESET + T_MS + T_LAT, "RESET length");
      wait_ms(2.0);
      ce_quiet(2.0);
      chk(tb_state == S_RECOVERY,      "still RECOVERY");
      ce_off(1'b1);

      // ENUM, step 1: the data stage of GET_DESCRIPTOR(DEVICE) NAKed forever
      dev.inject_fault(dev.F_NAK, dev.T_IN, 0, 6, 1, dev.ST_DATA, 0, -1, 0);
      wait_state(S_ENUM, 200.0);
      wait_ms(5.0);
      ce_quiet(2.0);
      chk(tb_state == S_ENUM,          "still ENUM at step 1");
      // EN = 0 abandons the open GET_DESCRIPTOR; the next bus reset closes it
      dev.chk_enable(dev.C_STATUS, 0);
      ce_off(1'b1);
      dev.clear_faults;
      wait_state(S_RECOVERY, 200.0);
      dev.chk_enable(dev.C_STATUS, 1);

      // ENUM, a later step: SET_IDLE (step 8) answered NAK in its status stage
      dev.inject_fault(dev.F_NAK, dev.T_IN, 0, 8'h0A, -1, dev.ST_STATUS, 0, -1, 0);
      wait_state(S_ENUM, 100.0);
      begin : ce_cfg
         integer k;
         for (k = 0; (k < 300) && (dev_configured !== 1'b1); k = k + 1)
           wait_ms(1.0);
      end
      chk(dev_configured === 1'b1,     "SET_CONFIGURATION done");
      wait_ms(5.0);
      ce_quiet(2.0);
      chk(tb_state == S_ENUM,          "still ENUM after SET_CONFIGURATION");
      rd(R_DEV_ID, 32'h0001_1209);
      rdv(R_DEV_EP, ce_v);
      chk(ce_v[3:0] == 4'd1,           "DEV_EP set by step 5 before EN = 0");
      // EN = 0 abandons the open SET_IDLE; the next bus reset closes it
      dev.chk_enable(dev.C_STATUS, 0);
      ce_off(1'b1);
      dev.clear_faults;
      wait_state(S_RESET, 102.0);
      wait_state(S_RECOVERY, 62.0);
      dev.chk_enable(dev.C_STATUS, 1);

      // The device enumerates after all of this
      wait_state(S_RUN, 300.0);
      status_chk(S_RUN, E_NONE, 4'd0);
      rd(R_DEV_ID, 32'h0001_1209);
      stimulus_done = 1;
   end
