//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    inact_gated
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : inact_gated.v
// Module Description : Inactive time under a gated clock: with nothing
//                      queued after a release the clock stops and INACT
//                      counts only requested edges, so the next assertion
//                      comes at least INACT half-periods of clock edges
//                      after the release however long the gap; with the next
//                      entry already queued the inactive time is exact.
//
// Doc "Clock request", "Chip selects" (INACT).
//----------------------------------------------------------------------------

integer    edges, i;

initial
   begin
      wait_reset_done(5);
      clk_set(4, 0);
      cs_set(8'h00, 1, 1, 16);
      ctrl_wr(C_EN | C_IDLE_HIGH);
      ent_tx(8, $urandom, 1'b0);
      wait (mon_txn === 1'b1);
      wait (mon_txn === 1'b0);
      // nothing queued: the clock stops during INACT
      edges = 0;
      for (i = 0; i < 300; i = i + 1) begin @(negedge free_clk); if (pclk_en) edges = edges + 1; end
      chk(edges < 10, "no clock requested during INACT with nothing queued");
      ent_tx(8, $urandom, 1'b0);
      edges = 0;
      while (mon_txn !== 1'b1) begin @(posedge pclk); edges = edges + 1; end
      if (FREE_CLK == 0) chk(edges >= 16 * 4 - 10, "INACT edges counted before the next assertion");
      wait_idle(100000);
      // next entry queued: exact
      ent_tx(8, $urandom, 1'b0);
      ent_tx(8, $urandom, 1'b0);
      wait_idle(100000);
      chk((t_meas_inact > 16 * 4 * PCLK_P - 0.01) && (t_meas_inact < 16 * 4 * PCLK_P + 0.01), "INACT exact with the entry queued");
      stimulus_done = 1;
   end
