//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    clk_stop
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : clk_stop.v
// Module Description : Start and stop of the clock generator: EN cleared at
//                      random points stops at the end of the frame (the
//                      launch of position D, after a delayed last bit),
//                      every output idle on that edge; STATUS.RUNNING reads
//                      1 until one BCLK half-period later (the tail) and
//                      CLKDIV / FORMAT / LOOPBACK writes are ignored until
//                      then; EN set again before the stop keeps the stream
//                      running, set in the tail starts after it; idle
//                      levels follow a FORMAT write
//                      (BCLK_INV, LRCK_INV, FSYNC).
//
// Doc "Clocks and sample rate" (start, stop, idle levels, RUNNING), "Register
// map" (CLKDIV, FORMAT and LOOPBACK ignored while running). The clock checker
// predicts the stop edge, the tail and the idle levels.
//----------------------------------------------------------------------------

reg [5:0] fl [0:5];
integer   fi, w;
reg [31:0] v;

initial
   begin
      wait_reset_done(5);
      fl[0] = F_I2S;  fl[1] = F_LJ | F_BCLK_INV;  fl[2] = F_DSPA;  fl[3] = F_DSPB | 6'b001000;
      fl[4] = F_I2S | F_SLOT16;  fl[5] = F_RJ | 6'b000010;
      for (fi = 0; fi < 6; fi = fi + 1)
        begin
           i2s_setup(1 + (fi % 2), fi % 5, fl[fi], fi[0]);
           i2s_start(0);
           wait_frames(1);
           w = $urandom % 900;
           repeat (w) @(posedge free_clk);
           #1;
           ctrl_wr(t_ctrl & ~C_EN);
           rdv(R_STATUS, v);
           @(posedge free_clk); #2;
           chk((v[31] === 1'b1) || !ck_busy, "STATUS.RUNNING reads 0 only once the engine has stopped");
           // locked while running
           if (ck_run)
             begin
                wr(R_FORMAT, 32'h3F);
                rd(R_FORMAT, {26'h0, fl[fi]});
             end
           if ((TX_EN != 0) && (RX_EN != 0) && (ck_run || (ck_tail > 2)))
             begin
                wr(R_CTRL, t_ctrl | C_LOOPBACK);
                rdv(R_CTRL, v);
                chk(v[12] === 1'b0, "LOOPBACK write ignored while the engine runs");
             end
           while (ck_busy) @(posedge free_clk);
           repeat (2) @(posedge free_clk);
           rdv(R_STATUS, v);
           chk(v[31] === 1'b0, "STATUS.RUNNING 0 after the stop");
        end

      // EN set again before the stop: the stream continues
      i2s_setup(2, 3'd0, F_I2S, 1'b0);
      i2s_start(0);
      wait_frames(1);
      ctrl_wr(t_ctrl & ~C_EN);
      ctrl_wr(t_ctrl | C_EN);
      wait_frames(2);
      chk(ck_run === 1'b1, "stream still running after EN cleared and set again");
      i2s_stop;

      // EN set again in the tail: the start waits for its end
      i2s_start(0);
      wait_frames(1);
      ctrl_wr(t_ctrl & ~C_EN);
      while (ck_run) @(posedge free_clk);
      #1;
      chk(ck_tail > 2, "the stop leaves a tail");
      ctrl_wr(t_ctrl | C_EN);
      wait_frames(1);
      chk(ck_run === 1'b1, "stream restarted after the tail");
      i2s_stop;

      // Idle levels follow FORMAT while stopped (checked by the clock checker)
      for (fi = 0; fi < 16; fi = fi + 1)
        begin
           wr(R_FORMAT, {26'h0, 2'b00, fi[3:2], 1'b1, fi[0]} | (fi[1] ? 32'h10 : 32'h0));
           d_fmt = {2'b00, fi[3:2], 1'b1, fi[0]} | (fi[1] ? 6'h10 : 6'h0);
           repeat (3) @(posedge free_clk);
        end
      wr(R_FORMAT, 32'h2);
      d_fmt = F_I2S;
      repeat (3) @(posedge free_clk);
      stimulus_done = 1;
   end
