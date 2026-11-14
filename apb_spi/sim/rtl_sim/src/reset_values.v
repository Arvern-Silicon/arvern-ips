//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    reset_values
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : reset_values.v
// Module Description : Reset values: every register, the aliases and the
//                      unmapped offsets read their documented value; the
//                      pins sit at the idle levels the IP drives from reset
//                      (SCK low, every select inactive, IO0 / IO2 / IO3
//                      driven high, IO1 an input); irq_o low and no clock
//                      requested while idle.
//
// Doc "Register map", "Ports" (pins out of reset), "Clock request".
//----------------------------------------------------------------------------

integer    a;

task pins_idle;
   input [80*8-1:0] when;
   begin
      if ((spi_sck !== 1'b0) || (spi_cs !== {CS_NR{1'b1}}) || (spi_io_o !== 4'b1101) || (spi_io_oe !== 4'b1101) || (irq !== 1'b0)) begin
         $display("ERROR: pins %0s: sck %b cs %b io %b oe %b irq %b %t ns", when, spi_sck, spi_cs, spi_io_o, spi_io_oe, irq, $time);
         error = error + 1;
      end
   end
endtask

initial
   begin
      // during the first reset, once a clock edge has passed
      wait (presetn === 1'b0);
      repeat (3) @(posedge free_clk); #1;
      pins_idle("during reset");
      wait_reset_done(5);
      pins_idle("after reset");
      repeat (10) @(posedge free_clk);
      chk(pclk_en === 1'b0, "no clock request while idle");
      rd(R_CFG,        CFG_VALUE);
      rd(R_CTRL,       32'h0000_0010);
      rd(R_CTRL_SET,   32'h0);
      rd(R_CTRL_CLR,   32'h0);
      rd(R_CLKDIV,     32'h0);
      rd(R_CSCFG,      32'h0);
      rd(R_XFER,       32'h0);
      rd(R_STATUS,     32'h4000_0000);
      rd(R_THRESH,     32'h0);
      rd(R_IRQ_EN,     32'h0);
      rd(R_IRQ_EN_SET, 32'h0);
      rd(R_IRQ_EN_CLR, 32'h0);
      rd(R_IRQ_PEND,   32'h1);
      rd(R_TXDATA,     32'h0);
      rd(R_CMD,        32'h0);
      rd(R_MDELEG,     MDELEG_RST_WORD);
      for (a = 32'h40; a < 32'h80; a = a + 4)
        if (a != 32'h60) rd(SPI_BASE + a, 32'h0);
      if (WIN_SIZE > 32'h80) begin rd(SPI_BASE + 32'h80, 32'h0); rd(SPI_BASE + WIN_SIZE - 4, 32'h0); end
      // the empty receive FIFO reads 0 (and flags RX_UDF)
      rd(R_RXDATA,     32'h0);
      rd(R_IRQ_PEND,   (RX_EN != 0) ? 32'h11 : 32'h01);
      pins_idle("after the reads");
      stimulus_done = 1;
   end
