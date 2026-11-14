//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    rx_stop_mono
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : rx_stop_mono.v
// Module Description : Mono receive stopped with a first sample held, with
//                      the driver's stop sequence (RX_ON then EN cleared, back
//                      to back): the held sample is dropped once the stream is
//                      inactive, so the next recording, started with EN and
//                      RX_ON in one write, packs its own samples in pairs from
//                      its first frame; STATUS.RX_ACTIVE reads 0 while stopped.
//
// Doc "Stream state" (mono receive), "Register map" (STATUS).
//----------------------------------------------------------------------------

integer    i, txl, rxl, n;
reg [31:0] v;

initial
   begin
      wait_reset_done(5);
      if (RX_EN == 0) tb_skip("no receive path");
      n = (RX_DEPTH < 4) ? RX_DEPTH : 4;
      for (i = 0; i < 3; i = i + 1)
        begin
           i2s_setup(1 + i, 3'd0, (i == 1) ? F_LJ : F_I2S, 1'b0);
           ctrl_wr(t_ctrl | C_RX_MONO);
           i2s_start(C_RX_ON);
           rx_wait_level(1);
           // stop with a first sample held
           while (tb_rx_half !== 1'b1) @(posedge free_clk);
           #1;
           ctrl_wr(t_ctrl & ~C_RX_ON);
           ctrl_wr(t_ctrl & ~C_EN);
           while (ck_busy) @(posedge free_clk);
           repeat (4) @(posedge free_clk);
           rdv(R_STATUS, v);
           chk(v[29] === 1'b0, "RX_ACTIVE reads 0 while stopped");
           chk(tb_rx_half === 1'b0, "held mono sample dropped by the stop");
           wr(R_CMD, 32'h2);
           // new recording: the first word pairs the first two new samples
           ctrl_wr(t_ctrl | C_EN | C_RX_ON);
           while (!ck_run || !mon_en_d || !src_en_d) @(posedge free_clk);
           rx_wait_level(n);
           rx_read(n);
           rx_check(n, 1'b1, 2'd0);
           chk(got_rx[0] === rx_exp_word(0, 1'b1, 2'd0), "first word of the new recording pairs its frames 0 and 1");
           i2s_stop;
           wr(R_CMD, 32'h2);
           ctrl_wr(0);
        end
      stimulus_done = 1;
   end
