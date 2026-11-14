//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    fifo_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : fifo_walk.v
// Module Description : Every FIFO entry written with all-ones and all-zeros:
//                      the transmit FIFO kept full while the engine takes a
//                      word per frame for three times the depth (the
//                      pointers wrap, blocks of depth words alternate the
//                      pattern), and the receive FIFO kept full by source
//                      frames in alternating blocks while one word is read
//                      per frame; every word sent and read is checked.
//
// Doc "Transmit and receive" (FIFO order); the walk is the register-space
// counterpart of the depth parameter sweep.
//----------------------------------------------------------------------------

integer i, n, txl, rxl, k, nw;
reg [31:0] w, v, e;

function [31:0] pat; input integer idx; input integer depth;
   pat = ((idx / depth) % 2) ? 32'h0000_0000 : 32'hFFFF_FFFF;
endfunction

initial
   begin
      wait_reset_done(5);
      i2s_setup(1, 3'd0, F_I2S | F_SLOT16, 1'b0);
      if (TX_EN != 0)
        begin
           n = 3 * TX_DEPTH;
           exp_tx_n = 0;
           for (k = 0; k < TX_DEPTH; k = k + 1) begin wr(R_TXDATA, pat(k, TX_DEPTH)); exp_tx[exp_tx_n] = pat(k, TX_DEPTH); exp_tx_n = exp_tx_n + 1; end
           mon_clear;
           i2s_start(C_TX_ON);
           nw = TX_DEPTH;
           while (nw < n)
             begin
                rd_levels(txl, rxl);
                if (txl < TX_DEPTH) begin wr(R_TXDATA, pat(nw, TX_DEPTH)); exp_tx[exp_tx_n] = pat(nw, TX_DEPTH); exp_tx_n = exp_tx_n + 1; nw = nw + 1; end
             end
           tx_wait_empty;
           i2s_stop;
           // the frames sent are the words written, in order (all-ones / zeros blocks)
           k = 0;
           for (i = 0; (i < mon_n) && ({mon_r[i], mon_l[i]} != 32'hFFFF_FFFF); i = i + 1) ;
           while ((i < mon_n) && (k < n))
             begin
                if ({mon_r[i], mon_l[i]} !== exp_tx[k])
                  begin $display("ERROR: walk TX -- frame %0d: 0x%h, expected 0x%h", k, {mon_r[i], mon_l[i]}, exp_tx[k]); error = error + 1; k = n; end
                i = i + 1;
                k = k + 1;
             end
           chk(k == n, "walk TX -- every word sent");
        end
      if (RX_EN != 0)
        begin
           n = 3 * RX_DEPTH;
           // source frames in alternating blocks of RX_DEPTH, from the next stream's first frame
           for (i = 0; i < 4 * RX_DEPTH + 8; i = i + 1)
             begin
                src_l[(src_base + 1000 + i) % MON_N] = pat(i, RX_DEPTH);
                src_r[(src_base + 1000 + i) % MON_N] = pat(i, RX_DEPTH);
             end
           i2s_start(C_RX_ON);
           rx_wait_level(RX_DEPTH);
           k = 0;
           while (k < n)
             begin
                rd_levels(txl, rxl);
                if (rxl >= RX_DEPTH - 1)
                  begin
                     rdv(R_RXDATA, v);
                     e = pat(k, RX_DEPTH);
                     if (v !== e) begin $display("ERROR: walk RX -- word %0d: 0x%h, expected 0x%h", k, v, e); error = error + 1; k = n; end
                     k = k + 1;
                  end
             end
           i2s_stop;
           wr(R_CMD, 32'h2);
        end
      stimulus_done = 1;
   end
