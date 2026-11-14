//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    clk_ratios
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : clk_ratios.v
// Module Description : Every RATIO with both slot sizes at MDIV 1, 2, 3 and
//                      7, MCLK on, and MDIV 256 once: the clock checker
//                      verifies every MCLK and BCLK half-period, the frame
//                      length and the edge alignment; the monitor checks
//                      LRCK at every sampling edge. MCLK_EN toggled while
//                      running in both MCLK phases: no partial pulse.
//
// Doc "Clocks and sample rate": MCLK half-period MDIV cycles, BCLK
// half-period MDIV * RATIO / (2 * S), LRCK period 2 * S BCLK periods;
// MCLK_EN takes effect at the next MCLK transition.
//----------------------------------------------------------------------------

integer md, rs, s16, ph;
integer mdl [0:3];

initial
   begin
      wait_reset_done(5);
      mdl[0] = 1; mdl[1] = 2; mdl[2] = 3; mdl[3] = 7;
      for (md = 0; md < 4; md = md + 1)
        for (rs = 0; rs < 5; rs = rs + 1)
          for (s16 = 0; s16 < 2; s16 = s16 + 1)
            begin
               i2s_setup(mdl[md], rs, s16 ? (F_I2S | F_SLOT16) : F_I2S, 1'b1);
               i2s_start(0);
               wait_frames(1);
               i2s_stop;
            end

      // Large divider, MCLK off (no stream: stop without the silence frames)
      i2s_setup(256, 3'd0, F_LJ, 1'b0);
      i2s_start(0);
      wait_frames(1);
      ctrl_wr(t_ctrl & ~C_EN);
      while (ck_busy) @(posedge free_clk);

      // MCLK_EN toggled while running, in both MCLK phases
      i2s_setup(3, 3'd1, F_I2S, 1'b1);
      i2s_start(0);
      for (ph = 0; ph < 6; ph = ph + 1)
        begin
           repeat (7 + ph) @(posedge free_clk);
           #1;
           ctrl_wr(t_ctrl ^ C_MCLK_EN);
           d_mclk_en = t_ctrl[3];
        end
      wait_frames(1);
      i2s_stop;
      stimulus_done = 1;
   end
