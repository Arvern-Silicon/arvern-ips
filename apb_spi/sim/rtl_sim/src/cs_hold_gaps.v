//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    cs_hold_gaps
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : cs_hold_gaps.v
// Module Description : One transaction continued across pauses: an empty
//                      transmit FIFO (the clock gated with the select held),
//                      EN cleared then set again, and a receive stall on a
//                      full FIFO; the select stays asserted throughout (one
//                      transaction) and every resume launches its frame with
//                      a full half-period of setup (the monitor's lane
//                      timing check), in both clock phases.
//
// Doc "Chip selects", "Frame format and clock modes" (resuming).
//----------------------------------------------------------------------------

integer    ph, n0, i;

initial
   begin
      wait_reset_done(5);
      cs_set(8'h00, 1, 1, 1);
      clk_set(2, 0);
      for (ph = 0; ph < 2; ph = ph + 1)
        begin
           ctrl_wr(C_EN | C_IDLE_HIGH | (ph ? (C_CPOL | C_CPHA) : 0));
           n0 = n_txn;
           // empty FIFO
           ent_tx(16, $urandom, 1'b1);
           wait_quiet(10000);
           repeat (100) @(posedge free_clk);
           ent_tx(8, $urandom, 1'b1);
           // EN cleared, entries queued, EN set
           wait_quiet(10000);
           wr(R_CTRL_CLR, C_EN);
           ent_tx(8, $urandom, 1'b1);
           ent_tx(24, $urandom, 1'b1);
           repeat (50) @(posedge free_clk);
           chk(apb_spi_inst0.tx_level == 2, "EN clear: entries wait");
           wr(R_CTRL_SET, C_EN);
           // receive stall: more frames than the FIFO holds, nothing popped
           if (RX_EN != 0)
             begin
                ent_drain = 0;
                for (i = 0; i < 2 * RX_DEPTH + 3; i = i + 1) rq_push($urandom);
                ent_rx(8, 2 * RX_DEPTH + 3, 1'b1);
                for (i = 0; i < 20000 && !apb_spi_inst0.core_stall; i = i + 1) @(posedge free_clk);
                chk(apb_spi_inst0.core_stall === 1'b1, "receive stall");
                repeat (100) @(posedge free_clk);
                ent_drain = 1;
                rx_drain;
             end
           ent_tx(8, $urandom, 1'b0);
           wait_idle(100000);
           rx_drain;
           chk(n_txn == n0 + 1, "one transaction across the pauses");
        end
      stimulus_done = 1;
   end
