//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tx_mono_race
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tx_mono_race.v
// Module Description : Mono transmit, TX_ON cleared by a CTRL write whose
//                      ACCESS edge is the frame boundary at which the engine
//                      takes a word's lower half: the upper half is discarded
//                      with the word, the FIFO drains, and a restart sends the
//                      next word from its lower half. The write is swept over
//                      the cycles around the boundary until it lands on it.
//
// Doc "Stream state" (mono transmit: clearing TX_ON discards a held upper
// half).
//----------------------------------------------------------------------------

integer    off, txl, rxl, hit;
reg [31:0] v;
reg        race_seen;

always @(posedge free_clk)
  if (psel && penable && pwrite && (paddr[ADDRW-1:2] == 'h01) && apb_i2s_inst0.tx_take && apb_i2s_inst0.ctrl_tx_mono &&
      !pwdata[1] && !tb_tx_half)
    race_seen = 1'b1;

initial
   begin
      race_seen = 1'b0;
      wait_reset_done(5);
      if (TX_EN == 0 || TX_DEPTH < 2) tb_skip("needs a transmit FIFO of two words");
      hit = 0;
      for (off = 0; (off < 10) && !hit; off = off + 1)
        begin
           i2s_setup(1, 3'd0, F_I2S, 1'b0);
           ctrl_wr(t_ctrl | C_TX_MONO);
           wr(R_TXDATA, 32'h1111_2222);
           wr(R_TXDATA, 32'h3333_4444);
           i2s_start(C_TX_ON);
           // the next rising edge takes the first word's upper half; the
           // lower half of the second word is taken one frame (512 edges) later
           @(negedge free_clk);
           while (!(apb_i2s_inst0.tx_take && tb_tx_half)) @(negedge free_clk);
           repeat (507 + off) @(posedge free_clk);
           #1;
           race_seen = 1'b0;
           ctrl_wr(t_ctrl & ~C_TX_ON);
           if (race_seen)
             begin
                hit = 1;
                repeat (2) @(posedge free_clk);
                chk(tb_tx_half === 1'b0, "TX_ON cleared at a lower-half take: no upper half left pending");
                rd_levels(txl, rxl);
                chk(txl == 0, "TX_ON cleared at a lower-half take: the word is discarded, the FIFO drains");
             end
           i2s_stop;
           wr(R_CMD, 32'h1);
           ctrl_wr(0);
        end
      chk(hit == 1, "the CTRL write landed on a lower-half take");
      stimulus_done = 1;
   end
