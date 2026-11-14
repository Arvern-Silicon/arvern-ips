//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    stop_timing
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : stop_timing.v
// Module Description : CTRL.EN cleared at every position of a frame, for a
//                      delayed format (I2S, DSP A, I2S with 16-bit slots) and
//                      an undelayed one (left-justified), with both streams
//                      on: the frame in progress always completes (the clock
//                      checker predicts the stop from the frame boundary
//                      taken with EN clear), every word that left the
//                      transmit FIFO is sent, and the receive side, with
//                      RX_DLY at its largest legal value, delivers its last
//                      frame before STATUS.RUNNING falls: the receive level no
//                      longer moves once RUNNING reads 0, and RX_ACTIVE reads
//                      0 then. The streams are cleared together with EN, the
//                      driver's sequence.
//
// Doc "Start, stop and idle levels", "Clock request", "Receive timing".
//----------------------------------------------------------------------------

reg [5:0]  fl [0:3];
integer    fi, p, n, txl, rxl, rxl0, k, taken;
reg [31:0] v;

initial
   begin
      wait_reset_done(5);
      fl[0] = F_I2S; fl[1] = F_DSPA; fl[2] = F_I2S | F_SLOT16; fl[3] = F_LJ;
      for (fi = 0; fi < 4; fi = fi + 1)
        for (p = 0; p < slot_w(fl[fi]) * 2; p = p + ((p < 3) ? 1 : 7))
          begin
             rx_dly = (RX_EN != 0) ? (2 * 4 * (fl[fi][5] ? 2 : 1) - 2) : 0;   // 2H - 2 at MDIV 1, RATIO 256
             i2s_setup(1, 3'd0, fl[fi], 1'b0);
             n = 0;
             exp_tx_n = 0;
             if (TX_EN != 0) begin n = (TX_DEPTH < 4) ? TX_DEPTH : 4; tx_push_random(n, 1'b0); end
             mon_clear;
             i2s_start(((TX_EN != 0) ? C_TX_ON : 0) | ((RX_EN != 0) ? C_RX_ON : 0));
             wait_frames(2);
             // EN (and the streams) cleared while position p is on the wire
             while (ck_pos != p) @(posedge free_clk);
             #1;
             ctrl_wr(t_ctrl & ~(C_EN | C_TX_ON | C_RX_ON));
             // RUNNING falls only after the last receive capture
             rdv(R_STATUS, v);
             while (v[31] === 1'b1) rdv(R_STATUS, v);
             chk(v[29] === 1'b0, "RX_ACTIVE reads 0 once RUNNING has fallen");
             rxl0 = v[24:16];
             for (k = 0; k < 6; k = k + 1)
               begin
                  repeat (3) @(posedge free_clk);
                  rd_levels(txl, rxl);
                  if (rxl != rxl0) begin $display("ERROR: receive level moved after RUNNING fell (%0d -> %0d), format 0x%h position %0d %t ns", rxl0, rxl, fl[fi], p, $time); error = error + 1; k = 6; end
               end
             // every word that left the transmit FIFO was sent in full
             if (TX_EN != 0)
               begin
                  rd_levels(txl, rxl);
                  taken = n - txl;
                  if (taken > 0) tx_check(taken);
               end
             while (ck_busy) @(posedge free_clk);
             wr(R_CMD, 32'h3);
          end
      rx_dly = 0;
      stimulus_done = 1;
   end
