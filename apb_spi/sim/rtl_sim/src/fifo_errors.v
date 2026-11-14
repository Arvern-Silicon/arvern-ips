//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    fifo_errors
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : fifo_errors.v
// Module Description : FIFO errors and refused entries: TX_OVF on a write to
//                      a full transmit FIFO (the entry dropped), RX_UDF on a
//                      read of the empty receive FIFO, XFER_ERR for every
//                      illegal XFER this build can be given (lane code 3,
//                      lanes beyond LANES_MAX, a frame length not a multiple
//                      of the lanes, a select beyond CS_NR, receiving kinds
//                      without RX_EN, POLL without POLL_EN), nothing pushed;
//                      a sparse TXDATA write pushes nothing and sets no
//                      flag; a W1C racing a new DONE.
//
// Doc "Refused entries", "IRQ_PEND".
//----------------------------------------------------------------------------

integer    i, l0, tries;

task refused;
   input [15:0] x;
   begin
      l0 = apb_spi_inst0.tx_level;
      wr(R_XFER, {16'h0, x});
      wr(R_TXDATA, 32'h1234);
      chk(apb_spi_inst0.tx_level == l0, "refused entry pushes nothing");
      irq_chk(I_XFER_ERR, I_XFER_ERR | I_TX_OVF);
   end
endtask

initial
   begin
      wait_reset_done(5);
      clk_set(1, 0);
      ctrl_wr(C_IDLE_HIGH);                     // EN clear
      // TX_OVF
      for (i = 0; i < TX_DEPTH; i = i + 1) ent_tx(8, i, 1'b0);
      chk(apb_spi_inst0.tx_level == TX_DEPTH, "transmit FIFO full");
      irq_chk(32'h0, I_TX_OVF);
      wr(R_TXDATA, 32'hDEAD);
      chk(n_tx_ovf == 1, "model: one overflow");
      irq_chk(I_TX_OVF, I_TX_OVF | I_XFER_ERR);
      wr(R_CMD, K_TX_FLUSH);
      chk(apb_spi_inst0.tx_level == 0, "flushed");
      // XFER_ERR causes
      refused(16'h0067);                                        // lanes code 3
      if (LANES_MAX < 2) refused(xa(KTX, 8, 2, 1'b0, 1'b0, 1'b0, 0));
      if (LANES_MAX < 4) refused(xa(KTX, 8, 4, 1'b0, 1'b0, 1'b0, 0));
      if (LANES_MAX >= 2) refused(xa(KTX, 7, 2, 1'b0, 1'b0, 1'b0, 0) | 16'h0000);
      if (LANES_MAX >= 4) refused(xa(KTX, 6, 4, 1'b0, 1'b0, 1'b0, 0));
      if (CS_NR < 8) refused(xa(KTX, 8, 1, 1'b0, 1'b0, 1'b0, CS_NR));
      if (RX_EN == 0)
        begin
           refused(xa(KRX, 8, 1, 1'b0, 1'b0, 1'b0, 0));
           refused(xa(KTX, 8, 1, 1'b1, 1'b0, 1'b0, 0));
        end
      if (!POLL_USE) refused(xa(KPOLL, 8, 1, 1'b0, 1'b0, 1'b0, 0));
      chk(n_xfer_err > 0, "model counted the refusals");
      // a select beyond CS_NR with CS_NONE is legal
      ent(xa(KTX, 8, 1, 1'b0, 1'b0, 1'b1, 7), 32'h5A);
      chk(apb_spi_inst0.tx_level == 1, "CS_NONE ignores the select number");
      wr(R_CMD, K_TX_FLUSH);
      // sparse TXDATA writes
      apb_write(1, MACHINE, R_TXDATA, 32'h55, SZ_B, OK);
      apb_write(1, MACHINE, R_TXDATA + 2, 32'h5555, SZ_H, OK);
      chk(apb_spi_inst0.tx_level == 0, "sparse TXDATA writes push nothing");
      irq_chk(32'h0, I_TX_OVF | I_XFER_ERR);
      // RX_UDF
      if (RX_EN != 0)
        begin
           rd(R_RXDATA, 32'h0);
           irq_chk(I_RX_UDF, I_RX_UDF);
        end
      // a W1C racing DONE: clear back to back while transactions end
      ctrl_wr(C_EN | C_IDLE_HIGH);
      for (tries = 0; tries < 40 && !cv_w1c_race; tries = tries + 1)
        begin
           ent_tx(8, 32'h00, 1'b0);
           repeat (tries % 7) @(posedge free_clk);
           for (i = 0; i < 12; i = i + 1) apb_write(0, MACHINE, R_IRQ_PEND, 32'h04, SZ_W, OK);
           apb_flush;
           wait_idle(10000);
        end
      chk(cv_w1c_race, "a W1C landed on the edge that set DONE");
      stimulus_done = 1;
   end
