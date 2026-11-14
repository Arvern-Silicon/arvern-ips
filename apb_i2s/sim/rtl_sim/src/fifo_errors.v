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
// Module Description : FIFO programming errors: a whole-word TXDATA write
//                      with the FIFO full is dropped and sets TX_OVF; a
//                      sparse write (PSTRB not 4'hF: byte and half-word
//                      stores on every lane) pushes nothing and sets no
//                      flag; an RXDATA read with the FIFO empty returns 0
//                      and sets RX_UDF; both raise irq_o when enabled.
//
// Doc "Register map" (TXDATA, RXDATA, IRQ_PEND and CMD lane 0), "Interrupts".
//----------------------------------------------------------------------------

reg [31:0] v;
integer txl, rxl, i;

initial
   begin
      wait_reset_done(5);
      if (TX_EN != 0)
        begin
           for (i = 0; i < TX_DEPTH; i = i + 1) wr(R_TXDATA, i + 1);
           rd_levels(txl, rxl);
           chk(txl == TX_DEPTH, "TX FIFO full");
           wr(R_TXDATA, 32'hDEAD);
           rd_levels(txl, rxl);
           chk(txl == TX_DEPTH, "TX FIFO level unchanged by a write when full");
           rdv(R_IRQ_PEND, v);
           chk(v[4] === 1'b1, "TX_OVF set by a write when full");
           wr(R_IRQ_EN, I_TX_OVF);
           chk(irq === 1'b1, "irq_o raised by TX_OVF");
           // IRQ_PEND and CMD act on lane 0 only
           apb_write(1, MACHINE, R_IRQ_PEND + 1, 32'hFF, SZ_B, OK);
           apb_write(1, MACHINE, R_IRQ_PEND + 2, 32'hFFFF, SZ_H, OK);
           apb_write(1, MACHINE, R_IRQ_PEND + 3, 32'hFF, SZ_B, OK);
           apb_write(1, MACHINE, R_CMD + 1, 32'hFF, SZ_B, OK);
           apb_write(1, MACHINE, R_CMD + 2, 32'hFFFF, SZ_H, OK);
           rdv(R_IRQ_PEND, v);
           chk(v[4] === 1'b1, "IRQ_PEND writes to lanes 1-3 clear nothing");
           rd_levels(txl, rxl);
           chk(txl == TX_DEPTH, "CMD writes to lanes 1-3 flush nothing");
           wr(R_IRQ_PEND, I_TX_OVF);
           wr(R_IRQ_EN, 0);
           wr(R_CMD, 32'h1);
           // sparse writes push nothing
           apb_write(1, MACHINE, R_TXDATA + 0, 32'h11, SZ_B, OK);
           apb_write(1, MACHINE, R_TXDATA + 1, 32'h22, SZ_B, OK);
           apb_write(1, MACHINE, R_TXDATA + 2, 32'h33, SZ_B, OK);
           apb_write(1, MACHINE, R_TXDATA + 3, 32'h44, SZ_B, OK);
           apb_write(1, MACHINE, R_TXDATA + 0, 32'h5555, SZ_H, OK);
           apb_write(1, MACHINE, R_TXDATA + 2, 32'h6666, SZ_H, OK);
           rd_levels(txl, rxl);
           chk(txl == 0, "sparse TXDATA writes push nothing");
           rdv(R_IRQ_PEND, v);
           chk(v[4] === 1'b0, "sparse TXDATA writes set no flag");
        end
      if (RX_EN != 0)
        begin
           rd(R_RXDATA, 32'h0);
           rdv(R_IRQ_PEND, v);
           chk(v[5] === 1'b1, "RX_UDF set by a read when empty");
           wr(R_IRQ_EN, I_RX_UDF);
           chk(irq === 1'b1, "irq_o raised by RX_UDF");
           wr(R_IRQ_PEND, I_RX_UDF);
           wr(R_IRQ_EN, 0);
        end
      stimulus_done = 1;
   end
