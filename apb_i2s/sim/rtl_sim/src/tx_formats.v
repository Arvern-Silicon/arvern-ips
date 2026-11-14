//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tx_formats
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tx_formats.v
// Module Description : Transmit in every FORMAT combination: the five named
//                      formats, I2S and the DSP modes with 16-bit slots
//                      (the delayed LSB straddles into the next slot),
//                      right-justified with DELAY set (ignored), each with
//                      BCLK_INV and LRCK_INV both ways. The device monitor
//                      decodes SD from the format definition and checks
//                      LRCK at every sampling edge.
//
// Doc "Frame format": DELAY, RJUST, LRCK_INV, FSYNC, BCLK_INV, SLOT16; zeros
// outside the sample field. Doc "Transmit and receive": the stream starts at
// a frame boundary with the prefilled words.
//----------------------------------------------------------------------------

reg [5:0] fl [0:7];
integer   fi, inv;
reg [5:0] f;

initial
   begin
      wait_reset_done(5);
      if (TX_EN == 0) tb_skip("no transmit path");
      fl[0] = F_I2S;  fl[1] = F_LJ;  fl[2] = F_RJ;  fl[3] = F_DSPA;  fl[4] = F_DSPB;
      fl[5] = F_I2S | F_SLOT16;  fl[6] = F_DSPA | F_SLOT16;  fl[7] = F_RJ | 6'b000010;
      for (fi = 0; fi < 8; fi = fi + 1)
        for (inv = 0; inv < 4; inv = inv + 1)
          begin
             f = fl[fi] ^ (inv[0] ? F_BCLK_INV : 6'b0) ^ (inv[1] ? 6'b001000 : 6'b0);
             $display("--- FORMAT 0x%h", f);
             i2s_setup(1, 3'd0, f, inv[0]);
             exp_tx_n = 0;
             tx_push_random((TX_DEPTH < 6) ? TX_DEPTH : 6, 1'b0);
             mon_clear;
             i2s_start(C_TX_ON);
             wait_frames(((TX_DEPTH < 6) ? TX_DEPTH : 6) + 3);
             i2s_stop;
             tx_check(exp_tx_n);
          end
      stimulus_done = 1;
   end
