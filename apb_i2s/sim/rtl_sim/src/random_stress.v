//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    random_stress
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : random_stress.v
// Module Description : Random streams: random MDIV (1-3), RATIO, FORMAT,
//                      mono modes and FIFO traffic, transmit checked by the
//                      monitor and receive from the source (or the loopback
//                      when both paths exist, at random), with random idle
//                      gaps, back-to-back transfers and refused accesses.
//
// Doc: every section; the device model and the clock checker check every
// stream.
//----------------------------------------------------------------------------

integer it, n, i, rxl, txl;
reg [5:0] f;
reg       mono, rmono, loop;
reg [1:0] sel;

initial
   begin
      wait_reset_done(5);
      for (it = 0; it < 12; it = it + 1)
        begin
           // PENABLE noise with PSEL low between transfers: ignored by the completer
           @(posedge free_clk); #1;
           psel = 1'b0; penable = 1'b1;
           @(posedge free_clk); #1;
           penable = 1'b0;
           f    = $urandom;
           if (f[4] && f[2]) f[2] = 1'b0;           // no right-justified frame-sync format
           mono = $urandom; rmono = $urandom; sel = $urandom % 3;
           loop = (TX_EN != 0) && (RX_EN != 0) && ($urandom % 3 == 0);
           i2s_setup(1 + ($urandom % 3), $urandom % 5, f, $urandom);
           ctrl_wr((t_ctrl & C_MCLK_EN) | ((TX_EN != 0) && mono ? C_TX_MONO : 0) |
                   ((RX_EN != 0) && rmono ? (C_RX_MONO | (sel << 8)) : 0));
           if (TX_EN != 0)
             begin
                n = 1 + ($urandom % ((TX_DEPTH < 5) ? TX_DEPTH : 5));
                exp_tx_n = 0;
                tx_push_random(n, mono);
                mon_clear;
             end
           if (loop)
             i2s_start(C_TX_ON | C_RX_ON | C_LOOPBACK);
           else
             i2s_start(((TX_EN != 0) ? C_TX_ON : 0) | ((RX_EN != 0) ? C_RX_ON : 0));
           wait_frames((TX_EN != 0) ? exp_tx_n + 2 : 6);
           // a refused access in the middle of the stream
           if (MDELEG_RST[1:0] != 2'b00) apb_write(1, USER, R_THRESH, 32'h1, SZ_W, exp_resp_of(1'b1, USER, R_THRESH));
           i2s_stop;
           if (TX_EN != 0) tx_check(exp_tx_n);
           if ((RX_EN != 0) && !loop)
             begin
                rd_levels(txl, rxl);
                if (rxl > 1)
                  begin
                     rx_read(rxl);
                     rx_check(rxl, rmono, sel);
                  end
             end
           wr(R_CMD, 32'h3);
           wr(R_THRESH, 32'h0);
           ctrl_wr(0);
        end
      stimulus_done = 1;
   end
