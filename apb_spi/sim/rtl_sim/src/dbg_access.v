//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dbg_access
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbg_access.v
// Module Description : Debugger accesses: with DBG_POP = 0 a debugger read
//                      of RXDATA returns the head without popping it and
//                      sets no RX_UDF on an empty FIFO; with DBG_POP = 1 it
//                      pops like a core read; a build with no debugger mask
//                      treats every access as the core's; debugger writes
//                      behave as the core's.
//
// Doc "Debugger accesses".
//----------------------------------------------------------------------------

integer    l0;
reg [31:0] v;

initial
   begin
      wait_reset_done(5);
      if (RX_EN == 0) tb_skip("needs the receive path");
      spi_setup(C_IDLE_HIGH, 1, 0);
      rq_push(32'h11); rq_push(32'h22); rq_push(32'h33);
      ent_rx(8, 3, 1'b0);
      wait_idle(100000);
      l0 = apb_spi_inst0.rx_level;
      tb_pmaster = 4'h9;                        // the Debug Module
      rdv(R_RXDATA, v);
      if (DBG_MASK != 4'h0)
        begin
           chk32(v, x_rx[x_rd], "debugger peek returns the head");
           chk(apb_spi_inst0.rx_level == l0, "debugger peek pops nothing");
           wr(R_CTRL_SET, C_DBG_POP);
           rdv(R_RXDATA, v);
           chk32(v, x_rx[x_rd], "debugger pop returns the head");
           x_rd = x_rd + 1;
           chk(apb_spi_inst0.rx_level == l0 - 1, "debugger pop with DBG_POP");
           wr(R_CTRL_CLR, C_DBG_POP);
        end
      else
        begin
           chk32(v, x_rx[x_rd], "no debugger mask: a core read");
           x_rd = x_rd + 1;
           chk(apb_spi_inst0.rx_level == l0 - 1, "no debugger mask: the read pops");
        end
      tb_pmaster = 4'h1;
      rx_drain;
      // empty FIFO
      wr(R_IRQ_PEND, 32'h7C);
      tb_pmaster = 4'h9;
      rd(R_RXDATA, 32'h0);
      tb_pmaster = 4'h1;
      irq_chk((DBG_MASK != 4'h0) ? 32'h0 : I_RX_UDF, I_RX_UDF);
      rd(R_RXDATA, 32'h0);
      irq_chk(I_RX_UDF, I_RX_UDF);
      stimulus_done = 1;
   end
