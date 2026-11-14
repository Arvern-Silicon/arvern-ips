//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    loopback
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : loopback.v
// Module Description : Internal loopback (CTRL.LOOPBACK): the receive FIFO
//                      gets the transmitted frames, in every named format
//                      and both slot sizes, through the receive synchroniser
//                      with RX_DLY 0 and 3. i2s_sd_i is held at 1 (ignored).
//
// Doc "Transmit and receive": LOOPBACK connects the serialiser output to the
// deserialiser input inside the IP; i2s_sd_o is still driven.
//----------------------------------------------------------------------------

reg [5:0] fl [0:6];
integer   fi, d, i, n, first;
reg [31:0] w [0:7];

initial
   begin
      wait_reset_done(5);
      if ((TX_EN == 0) || (RX_EN == 0)) tb_skip("loopback needs both paths");
      fl[0] = F_I2S;  fl[1] = F_LJ;  fl[2] = F_RJ;  fl[3] = F_DSPA;  fl[4] = F_DSPB;
      fl[5] = F_I2S | F_SLOT16 | F_BCLK_INV;  fl[6] = F_DSPA | F_SLOT16;
      n = (TX_DEPTH < 4) ? TX_DEPTH : 4;
      if (RX_DEPTH < n + 4) n = (RX_DEPTH > 4) ? RX_DEPTH - 4 : 1;
      dev_rt = 0;
      force i2s_sd_dev = 1'b1;
      for (d = 0; d < 2; d = d + 1)
        for (fi = 0; fi < 7; fi = fi + 1)
          begin
             rx_dly = d * 3;
             i2s_setup(1, 3'd0, fl[fi], 1'b0);
             for (i = 0; i < n; i = i + 1) begin w[i] = $urandom | 32'h00010001; wr(R_TXDATA, w[i]); end
             i2s_start(C_TX_ON | C_RX_ON | C_LOOPBACK);
             wait_frames(n + 3);
             i2s_stop;
             // received: zero frames, then the transmitted words in order
             rx_read((RX_DEPTH < n + 4) ? RX_DEPTH : n + 4);
             first = -1;
             for (i = 0; (i < n + 4) && (i < RX_DEPTH) && (first < 0); i = i + 1)
               if (got_rx[i] == w[0]) first = i;
               else chk32(got_rx[i], 32'h0, "LOOP -- silence before the stream");
             if (first < 0) tb_error("LOOP -- first word not received");
             else
               for (i = 1; (i < n) && (first + i < RX_DEPTH); i = i + 1)
                 chk32(got_rx[first + i], w[i], "LOOP -- received word");
             wr(R_CMD, 32'h3);
             ctrl_wr(t_ctrl & ~C_LOOPBACK);
          end
      release i2s_sd_dev;
      stimulus_done = 1;
   end
