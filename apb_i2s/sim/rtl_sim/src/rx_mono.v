//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    rx_mono
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : rx_mono.v
// Module Description : Mono receive: the left sample, the right one or their
//                      average (arithmetic shift of the 17-bit sum, with the
//                      signed extremes) is kept and two consecutive samples
//                      make a word, the first in the lower half; RX_MONO and
//                      RX_MONO_SEL are ignored while RX_ON; a lone first
//                      sample is dropped once the stream is inactive.
//
// Doc "Sample packing", "Stream state".
//----------------------------------------------------------------------------

integer sel, n, i;
reg [31:0] v;

initial
   begin
      wait_reset_done(5);
      if (RX_EN == 0) tb_skip("no receive path");
      n = (RX_DEPTH < 4) ? RX_DEPTH : 4;
      // signed extremes in the first source frames of every stream
      for (i = 0; i < MON_N; i = i + 1)
        if ((i % 7) == 3) begin src_l[i] = 16'h8000; src_r[i] = 16'h8000; end
        else if ((i % 7) == 5) begin src_l[i] = 16'h7FFF; src_r[i] = 16'h7FFF; end
        else if ((i % 7) == 6) begin src_l[i] = 16'h8000; src_r[i] = 16'h7FFF; end
      for (sel = 0; sel < 3; sel = sel + 1)
        begin
           i2s_setup(1, 3'd0, F_LJ, 1'b0);
           ctrl_wr((t_ctrl & ~32'h300) | C_RX_MONO | (sel << 8));
           rx_fill(n);
           rx_read(n);
           rx_check(n, 1'b1, sel);
           wr(R_CMD, 32'h2);
        end
      // locked while RX_ON
      ctrl_wr(C_RX_ON);
      ctrl_wr(C_RX_ON | C_RX_MONO | C_RX_SEL_AVG);
      rdv(R_CTRL, v);
      chk(v[6] === 1'b0, "RX_MONO write ignored while RX_ON");
      chk(v[9:8] === 2'b00, "RX_MONO_SEL write ignored while RX_ON");
      ctrl_wr(0);
      // a lone first sample is dropped when the stream stops
      ctrl_wr(C_RX_MONO);
      i2s_setup(1, 3'd0, F_I2S, 1'b0);
      i2s_start(C_RX_ON);
      while (tb_rx_half !== 1'b1) @(posedge free_clk);
      #1;
      ctrl_wr(t_ctrl & ~C_RX_ON);
      while (apb_i2s_inst0.rx_active) @(posedge free_clk);
      repeat (2) @(posedge free_clk);
      chk(tb_rx_half === 1'b0, "RX mono -- lone sample dropped when the stream is inactive");
      i2s_stop;
      ctrl_wr(0);
      stimulus_done = 1;
   end
