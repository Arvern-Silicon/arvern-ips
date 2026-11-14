//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    cs_none
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : cs_none.v
// Module Description : Clocks with no chip select: 80 DUMMY clocks with every
//                      select inactive and IO0 driven high (the SD power-up
//                      requirement), transmit and receive entries with
//                      CS_NONE, each its own transaction with its setup,
//                      hold and inactive times; a held select released for a
//                      CS_NONE entry; CS_HOLD ignored on a CS_NONE entry.
//
// Doc "Chip selects" (clocks with no chip select).
//----------------------------------------------------------------------------

integer    n0;

initial
   begin
      wait_reset_done(5);
      cs_set(8'h00, 2, 2, 2);
      spi_setup(C_IDLE_HIGH, 3, 0);
      n0 = n_txn;
      ent(xa(KDUMMY, 8, 1, 1'b0, 1'b0, 1'b1, 0), 79);
      wait_idle(100000);
      chk(n_txn == n0 + 1, "power-up clocks: one transaction");
      chk(n_frames >= 80, "80 clocks");
      ent(xa(KTX, 16, 1, 1'b0, 1'b1, 1'b1, 0), $urandom);    // CS_HOLD ignored
      if (RX_EN != 0) begin rq_push($urandom); ent(xa(KRX, 8, 1, 1'b0, 1'b0, 1'b1, 0), 0); end
      ent(xa(KTX, 8, 1, 1'b0, 1'b1, 1'b0, 0), $urandom);
      ent(xa(KDUMMY, 8, 1, 1'b0, 1'b0, 1'b1, 0), 7);
      wait_idle(100000);
      rx_drain;
      chk(n_txn == n0 + ((RX_EN != 0) ? 5 : 4), "each CS_NONE entry a transaction of its own");
      stimulus_done = 1;
   end
