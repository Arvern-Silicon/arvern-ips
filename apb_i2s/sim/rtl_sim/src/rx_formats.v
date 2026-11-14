//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    rx_formats
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : rx_formats.v
// Module Description : Receive in every FORMAT combination (the transmit
//                      list of tx_formats), from the device source with a
//                      10 ns round trip: the words read are consecutive
//                      source frames.
//
// Doc "Frame format", "Transmit and receive": the frame pushed at the end of
// each frame that started with RX_ON; the 16 sample bits of each slot.
//----------------------------------------------------------------------------

reg [5:0] fl [0:7];
integer   fi, inv, n;
reg [5:0] f;

initial
   begin
      wait_reset_done(5);
      if (RX_EN == 0) tb_skip("no receive path");
      fl[0] = F_I2S;  fl[1] = F_LJ;  fl[2] = F_RJ;  fl[3] = F_DSPA;  fl[4] = F_DSPB;
      fl[5] = F_I2S | F_SLOT16;  fl[6] = F_DSPA | F_SLOT16;  fl[7] = F_RJ | 6'b000010;
      n = (RX_DEPTH < 6) ? RX_DEPTH : 6;
      for (fi = 0; fi < 8; fi = fi + 1)
        for (inv = 0; inv < 4; inv = inv + 1)
          begin
             f = fl[fi] ^ (inv[0] ? F_BCLK_INV : 6'b0) ^ (inv[1] ? 6'b001000 : 6'b0);
             $display("--- FORMAT 0x%h", f);
             i2s_setup(1, 3'd0, f, 1'b0);
             rx_fill(n);
             rx_read(n);
             rx_check(n, 1'b0, 2'd0);
             wr(R_CMD, 32'h2);
          end
      stimulus_done = 1;
   end
