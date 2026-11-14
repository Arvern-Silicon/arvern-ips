//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    stream_start_stop
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : stream_start_stop.v
// Module Description : Stream on / off at frame boundaries: TX_ON set in the
//                      middle of a frame transmits from the next boundary
//                      (zeros until then), TX_ON cleared finishes the frame
//                      then sends zeros, RX_ON set mid-frame receives from
//                      the next whole frame, RX_ON cleared completes the
//                      frame in progress; STATUS.TX_ACTIVE / RX_ACTIVE
//                      follow the boundaries.
//
// Doc "Transmit and receive", "Register map" (STATUS).
//----------------------------------------------------------------------------

integer txl, rxl, i, w;
reg [31:0] v;

initial
   begin
      wait_reset_done(5);
      i2s_setup(1, 3'd2, F_LJ, 1'b0);
      i2s_start(0);
      if (TX_EN != 0)
        begin
           exp_tx_n = 0;
           tx_push_random((TX_DEPTH < 3) ? TX_DEPTH : 3, 1'b0);
           mon_clear;
           repeat ($urandom % 500) @(posedge free_clk);
           #1;
           ctrl_wr(t_ctrl | C_TX_ON);
           rdv(R_STATUS, v);
           wait_frames(1);
           rdv(R_STATUS, v);
           chk(v[30] === 1'b1, "TX_ACTIVE after the boundary");
           wait_frames((TX_DEPTH < 3) ? TX_DEPTH + 1 : 4);
           ctrl_wr(t_ctrl & ~C_TX_ON);
           wait_frames(2);
           rdv(R_STATUS, v);
           chk(v[30] === 1'b0, "TX_ACTIVE cleared at the boundary after TX_ON cleared");
           tx_check(exp_tx_n);
           for (i = mon_n - 1; i >= mon_n - 1; i = i - 1)
             chk32({mon_r[i], mon_l[i]}, 32'h0, "zero frame after TX_ON cleared");
        end
      if (RX_EN != 0)
        begin
           repeat ($urandom % 500) @(posedge free_clk);
           #1;
           ctrl_wr(t_ctrl | C_RX_ON);
           rx_wait_level(1);
           rdv(R_STATUS, v);
           chk(v[29] === 1'b1, "RX_ACTIVE while receiving");
           w = $urandom % 500;
           repeat (w) @(posedge free_clk);
           #1;
           ctrl_wr(t_ctrl & ~C_RX_ON);
           wait_frames(2);
           rdv(R_STATUS, v);
           chk(v[29] === 1'b0, "RX_ACTIVE cleared after the last frame");
           rd_levels(txl, rxl);
           rx_read(rxl);
           rx_check(rxl, 1'b0, 2'd0);
        end
      i2s_stop;
      stimulus_done = 1;
   end
