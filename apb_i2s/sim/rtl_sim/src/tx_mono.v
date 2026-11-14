//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tx_mono
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tx_mono.v
// Module Description : Mono transmit: each half-word is sent in both slots,
//                      the lower half first; an underrun between words
//                      re-aligns the pair (the next word starts with its
//                      lower half); clearing TX_ON with an upper half held
//                      discards it (the word leaves the FIFO); TX_MONO is
//                      ignored while TX_ON is set.
//
// Doc "Sample packing", "Stream state": mono transmit, underrun, stop.
//----------------------------------------------------------------------------

integer n, txl, rxl, i;
reg [31:0] v;

initial
   begin
      wait_reset_done(5);
      if (TX_EN == 0) tb_skip("no transmit path");
      n = (TX_DEPTH < 5) ? TX_DEPTH : 5;

      // Plain mono stream
      i2s_setup(1, 3'd0, F_I2S, 1'b0);
      ctrl_wr(t_ctrl | C_TX_MONO);
      exp_tx_n = 0;
      tx_push_random(n, 1'b1);
      mon_clear;
      i2s_start(C_TX_ON);
      wait_frames(2 * n + 3);
      i2s_stop;
      tx_check(exp_tx_n);

      // Underrun mid-stream: re-aligns on the next word
      exp_tx_n = 0;
      tx_push_random(1, 1'b1);
      mon_clear;
      i2s_start(C_TX_ON);
      wait_frames(5);
      v = $urandom | 32'h00010001;
      wr(R_TXDATA, v);
      wait_frames(4);
      i2s_stop;
      tx_check(2);
      // the second word's two frames follow, after zero frames
      for (i = 0; (i < mon_n) && ({mon_r[i], mon_l[i]} != mono_frame(v, 1'b0)); i = i + 1) ;
      chk(i < mon_n - 1, "TX mono -- word after the underrun sent");
      if (i < mon_n - 1) chk32({mon_r[i + 1], mon_l[i + 1]}, mono_frame(v, 1'b1), "TX mono -- upper half after the underrun");

      // TX_ON cleared with an upper half held: the word is discarded
      if (TX_DEPTH >= 2)
        begin
           wr(R_CMD, 32'h1);
           tx_push_random(2, 1'b1);
           i2s_start(C_TX_ON);
           // stop transmitting after the first frame of the first word
           while (tb_tx_half !== 1'b1) @(posedge free_clk);
           #1;
           ctrl_wr(t_ctrl & ~C_TX_ON);
           rd_levels(txl, rxl);
           chk(txl == 1, "TX mono -- TX_ON cleared: the held word is discarded");
           i2s_stop;
           wr(R_CMD, 32'h1);
        end

      // TX_MONO ignored while TX_ON
      ctrl_wr(C_TX_ON);
      ctrl_wr(C_TX_ON | C_TX_MONO);
      rdv(R_CTRL, v);
      chk(v[5] === 1'b0, "TX_MONO write ignored while TX_ON");
      ctrl_wr(0);
      stimulus_done = 1;
   end
