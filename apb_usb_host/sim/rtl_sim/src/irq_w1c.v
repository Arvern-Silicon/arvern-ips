//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    irq_w1c
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : irq_w1c.v
// Module Description : IRQ_EN masks each IRQ_PEND cause to irq_o (STATE,
//                      XFER_DONE, READY, REPORT, XFER_PKT, DETACH, FAIL);
//                      the W1C clears only the written bits and only through
//                      byte lane 0; a cause set in the same cycle as its W1C
//                      stays set: W1C writes of STATE are swept across the
//                      cycle in which an attach or a detach changes the
//                      state, and every read of IRQ_PEND.STATE is checked
//                      against the state changes seen on tb_state (a change
//                      at or after the W1C edge must read 1, no change near
//                      or after it must read 0).
//
// Doc "Register map" (IRQ_EN, IRQ_PEND), "Ports" (irq_o), "States",
// "Control transfers".
//----------------------------------------------------------------------------

integer    iw_i;
integer    iw_p;
integer    iw_dl;
integer    iw_nw;
integer    iw_races = 0;
integer    iw_ambig = 0;                     // checks with a change just before the W1C edge
integer    iw_lat [0:1];                     // line change -> state change, cycles (0 detach, 1 attach)
reg [31:0] iw_v;
reg  [7:0] iw_seq;
reg  [6:0] iw_len;
reg [63:0] iw_dat;
reg  [3:0] iw_target;
real       iw_t0;
real       iw_ew = -1.0e15;                  // ACCESS edge of the last W1C that included STATE
real       iw_chg_t [0:15];                  // times of the last state changes
integer    iw_nchg = 0;

always @(posedge st_tgl or negedge st_tgl)
  if (tb_rst_done === 1'b1)
    begin
       iw_chg_t[iw_nchg % 16] = $realtime;
       iw_nchg = iw_nchg + 1;
    end

// Any state change within [lo, hi] (ns)
function iw_chg_in;
   input real lo;
   input real hi;
   integer    k;
   begin
      iw_chg_in = 1'b0;
      for (k = 0; (k < iw_nchg) && (k < 16); k = k + 1)
        if ((iw_chg_t[k] >= lo) && (iw_chg_t[k] <= hi)) iw_chg_in = 1'b1;
   end
endfunction

// W1C of IRQ_PEND in Machine mode, recording the ACCESS edge when STATE is written
task iw_w1c;
   input [31:0] m;
   begin
      wr(R_IRQ_PEND, m);
      if (m[6]) iw_ew = $realtime - 1.0;
   end
endtask

// Read IRQ_PEND.STATE and check it against the state changes since the last
// STATE W1C. The read shows the register after the edge before the one that
// ends its ACCESS cycle (er - P); the set is allowed up to two cycles after
// the change. A change at or after the W1C edge, old enough to be visible,
// must read 1; no change from two cycles before the W1C edge to the read must
// read 0; a change one or two cycles before the W1C edge allows either value;
// a change too recent to be visible is read again.
task iw_check;
   input [80*8-1:0] msg;
   integer    n;
   reg        done;
   reg [31:0] v;
   real       er;
   real       p;
   begin
      p    = PCLK_P;
      n    = 0;
      done = 1'b0;
      while (!done && (n < 20))
        begin
           rdv(R_IRQ_PEND, v);
           er = $realtime - 1.0;
           if (iw_chg_in(iw_ew - 0.25 * p, er - 2.75 * p))
             begin
                if (v[6] !== 1'b1)
                  begin
                     $display("ERROR: IRQ_PEND.STATE lost: a state change at or after the W1C edge reads 0 (%0s) %t ns",
                              msg, $time);
                     error = error + 1;
                  end
                if (iw_chg_in(iw_ew - 0.25 * p, iw_ew + 0.25 * p)) iw_races = iw_races + 1;
                done = 1'b1;
             end
           else if (iw_chg_in(iw_ew - 0.25 * p, er - 0.75 * p))
             ;                               // a change too recent to be visible yet: read again
           else if (iw_chg_in(iw_ew - 2.25 * p, iw_ew - 0.25 * p))
             begin
                iw_ambig = iw_ambig + 1;     // set one or two cycles before the W1C edge: either value
                done     = 1'b1;
             end
           else
             begin
                if (v[6] !== 1'b0)
                  begin
                     $display("ERROR: IRQ_PEND.STATE reads 1 with no state change since its W1C (%0s) %t ns", msg, $time);
                     error = error + 1;
                  end
                done = 1'b1;
             end
           n = n + 1;
        end
      if (!done) tb_error("IRQ_PEND.STATE check never conclusive");
   end
endtask

task iw_settle;
   begin
      @(posedge free_clk);
      @(posedge free_clk);
      #1;
   end
endtask

// Cause k pending: IRQ_EN masks it to irq_o, W1C clears only the written bits
// and only through lane 0
task iw_mask;
   input integer k;
   reg   [31:0]  b;
   reg   [31:0]  v;
   begin
      b = 32'h1 << k;
      rdv(R_IRQ_PEND, v);
      if (v[k] !== 1'b1)
        begin
           $display("ERROR: IRQ_PEND.%0s not set (IRQ_PEND 0x%h) %t ns", irq_name(k), v, $time);
           error = error + 1;
        end
      iw_w1c(I_ALL & ~b);
      rd(R_IRQ_PEND, b);
      wr(R_IRQ_EN, 32'h0);
      iw_settle;
      chk(irq === 1'b0, "irq_o low with IRQ_EN = 0");
      wr(R_IRQ_EN, b);
      iw_settle;
      chk(irq === 1'b1, "irq_o high with the cause enabled");
      wr(R_IRQ_EN, I_ALL & ~b);
      iw_settle;
      chk(irq === 1'b0, "irq_o low with every other cause enabled");
      wr(R_IRQ_EN, I_ALL);
      iw_settle;
      chk(irq === 1'b1, "irq_o high with every cause enabled");
      apb_write(1, MACHINE, R_IRQ_PEND + 1, 32'hFF, SZ_B, OK);
      apb_write(1, MACHINE, R_IRQ_PEND + 2, 32'hFFFF, SZ_H, OK);
      rd(R_IRQ_PEND, b);
      wr(R_IRQ_PEND, 32'h0);
      rd(R_IRQ_PEND, b);
      iw_w1c(b);
      rd(R_IRQ_PEND, 32'h0);
      iw_settle;
      chk(irq === 1'b0, "irq_o low once the cause is cleared");
      wr(R_IRQ_EN, 32'h0);
   end
endtask

// Poll IRQ_PEND until bit k is set, at most ms
task iw_wait_pend;
   input integer k;
   input real    ms;
   reg   [31:0]  v;
   real          t0;
   begin
      t0 = $realtime;
      rdv(R_IRQ_PEND, v);
      while ((v[k] !== 1'b1) && ($realtime - t0 < ms * T_MS))
        begin
           #(100.0e3);
           rdv(R_IRQ_PEND, v);
        end
      if (v[k] !== 1'b1)
        begin
           $display("ERROR: IRQ_PEND.%0s not set within %0.1f ms %t ns", irq_name(k), ms, $time);
           error = error + 1;
        end
   end
endtask

task iw_quiet;
   begin
      while (!((usb_oe === 1'b0) && (dev.drv_en === 1'b0) && ($realtime - tb_act_t >= 100.0e3)))
        #(10.0e3);
   end
endtask

initial
   begin
      wait_reset_done(5);
      rd(R_IRQ_PEND, 32'h0);
      rd(R_IRQ_EN, 32'h0);
      chk(irq === 1'b0, "irq_o low out of reset");

      // STATE: OFF -> DETACHED
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0);
      wait_state(S_DETACHED, 1.0);
      iw_settle;
      chk(irq === 1'b0, "IRQ_EN = 0 masks STATE");
      iw_check("OFF -> DETACHED");
      iw_mask(6);
      iw_check("after the STATE mask checks");

      // Latency from a line change to the state change, for an attach
      // (DETACHED -> DEBOUNCE) and a detach (DEBOUNCE -> DETACHED)
      for (iw_i = 0; iw_i < 2; iw_i = iw_i + 1)
        begin
           @(posedge free_clk);
           #1;
           iw_t0 = $realtime - 1.0;
           dev.attach(dev.P_KBD);
           wait_state(S_DEBOUNCE, 3.0);
           iw_lat[1] = $rtoi(($realtime - iw_t0) / PCLK_P + 0.5);
           iw_settle;
           iw_check("attach");
           iw_w1c(I_STATE);
           @(posedge free_clk);
           #1;
           iw_t0 = $realtime - 1.0;
           dev.detach;
           wait_state(S_DETACHED, 3.0);
           iw_lat[0] = $rtoi(($realtime - iw_t0) / PCLK_P + 0.5);
           iw_settle;
           iw_check("detach");
           iw_w1c(I_STATE);
           iw_check("cleared");
        end
      $display("INFO: line change to state change: attach %0d, detach %0d cycles", iw_lat[1], iw_lat[0]);

      // The W1C ACCESS edge swept from 3 cycles before to 3 cycles after the
      // state change, for attaches and detaches, then 32 passes at random
      // offsets within +-24 cycles (the line sampling may add jitter)
      for (iw_p = 0; iw_p < 74; iw_p = iw_p + 1)
        begin
           iw_dl     = (iw_p < 42) ? ((iw_p / 2) % 7 - 3) : (($urandom % 49) - 24);
           iw_target = dev_attached ? S_DETACHED : S_DEBOUNCE;
           iw_nw     = (dev_attached ? iw_lat[0] : iw_lat[1]) + iw_dl - 2;
           if (iw_nw < 0) iw_nw = 0;
           @(posedge free_clk);
           #1;
           if (dev_attached) dev.detach;
           else              dev.attach(dev.P_KBD);
           repeat (iw_nw) @(posedge free_clk);
           #1;
           iw_w1c(I_STATE);
           iw_check("W1C swept across the state change");
           wait_state(iw_target, 3.0);
           iw_settle;
           iw_check("after the state change");
           iw_w1c(I_STATE);
           iw_check("cleared after the sweep step");
        end
      $display("INFO: %0d STATE W1C writes landed on the state-change edge, %0d one or two cycles after it",
               iw_races, iw_ambig);
      if (dev_attached) dev.detach;
      wait_state(S_DETACHED, 3.0);
      iw_settle;
      iw_check("detached");
      iw_w1c(I_ALL);

      // XFER_DONE: XFER_START outside RUN is refused at once (CTRL_EN = 1);
      // with CTRL_EN = 0 the command is ignored
      wr(R_CMD, K_XFER_START);
      iw_settle;
      if (CTRL_EN != 0)
        begin
           rd(R_XFER, {20'h0, X_REFUSED, 9'h0});
           iw_mask(5);
        end
      else
        begin
           rd(R_XFER, 32'h0);
           rd(R_IRQ_PEND, 32'h0);
        end

      // Enumeration: every state change reads 1 before it is cleared
      iw_check("before the enumeration");
      dev.attach(dev.P_KBD);
      iw_i = 0;
      while ((tb_state !== S_RUN) && (iw_i < 20))
        begin
           wait_state_not(tb_state, 400.0);
           repeat ($urandom % 8) @(posedge free_clk);
           #1;
           iw_check("enumeration step");
           if (tb_state !== S_RUN) iw_w1c(I_STATE);
           iw_i = iw_i + 1;
        end
      chk(tb_state === S_RUN, "RUN reached");
      iw_mask(1);                            // READY

      // REPORT
      read_report(iw_len, iw_seq, iw_dat);
      dev.push_report(8, 64'h0807_0605_0403_0201);
      expect_report(iw_seq, 8, 64'h0807_0605_0403_0201, 50.0);
      iw_mask(0);

      // XFER_PKT and XFER_DONE of a GET_DESCRIPTOR(DEVICE, 8) run by software
      if (CTRL_EN != 0)
        begin
           wr(R_SETUP0, 32'h0100_0680);
           wr(R_SETUP1, 32'h0008_0000);
           wr(R_CMD, K_XFER_START);
           iw_wait_pend(4, 50.0);
           rdv(R_XFER, iw_v);
           chk32(iw_v & 32'h17F, 32'h108, "XFER.PKT and LEN 8 after the data packet");
           iw_mask(4);
           wr(R_CMD, K_XFER_NEXT);
           iw_wait_pend(5, 50.0);
           rdv(R_XFER, iw_v);
           chk32(iw_v & 32'hF00, {20'h0, X_OK, 9'h0}, "XFER.RESULT OK, PKT clear");
           iw_mask(5);
        end

      // DETACH: a disconnect in RUN, at a quiet moment
      iw_quiet;
      dev.detach;
      wait_state(S_DETACHED, 5.0);
      iw_settle;
      rdv(R_IRQ_PEND, iw_v);
      chk32(iw_v & (I_DETACH | I_STATE | I_FAIL), I_DETACH | I_STATE, "DETACH and STATE after a disconnect in RUN");
      iw_mask(2);

      // FAIL: a hub ends UNSUPPORTED after step 1
      dev.attach(dev.P_HUB);
      wait_state(S_UNSUPPORTED, 400.0);
      status_chk(S_UNSUPPORTED, E_HUB, 4'd1);
      iw_mask(3);

      stimulus_done = 1;
   end
