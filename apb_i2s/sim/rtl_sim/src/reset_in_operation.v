//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    reset_in_operation
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : reset_in_operation.v
// Module Description : Reset asserted with the engine streaming in both
//                      directions (and a mono half held): outputs idle at
//                      once (asynchronous style) or on the next requested
//                      edge (synchronous style), FIFOs empty, RUNNING 0,
//                      and a new stream works afterwards.
//
// Doc "Parameters" (ASYNC_RST_EN), "Clocks and sample rate".
//----------------------------------------------------------------------------

integer txl, rxl;
reg [31:0] v;

initial
   begin
      wait_reset_done(5);
      i2s_setup(2, 3'd1, F_DSPA, 1'b1);
      if (TX_EN != 0) begin ctrl_wr(t_ctrl | C_TX_MONO); tx_push_random((TX_DEPTH < 4) ? TX_DEPTH : 4, 1'b1); end
      i2s_start(((TX_EN != 0) ? C_TX_ON : 0) | ((RX_EN != 0) ? C_RX_ON : 0));
      wait_frames(3);
      repeat ($urandom % 200) @(posedge free_clk);
      tb_reset_pulse;
      chk(i2s_mclk === 1'b0, "MCLK low after reset");
      chk(i2s_bclk === 1'b0, "BCLK idle after reset");
      chk(i2s_lrck === 1'b1, "LRCK idle (I2S) after reset");
      chk(i2s_sd_o === 1'b0, "SD low after reset");
      rd(R_STATUS, 32'h0);
      rd(R_CTRL, 32'h0);
      // a new stream after the reset
      if ((TX_EN != 0) && (RX_EN != 0))
        begin
           i2s_setup(1, 3'd0, F_I2S, 1'b0);
           exp_tx_n = 0;
           tx_push_random((TX_DEPTH < 3) ? TX_DEPTH : 3, 1'b0);
           mon_clear;
           i2s_start(C_TX_ON);
           wait_frames(5);
           i2s_stop;
           tx_check(exp_tx_n);
        end
      stimulus_done = 1;
   end
