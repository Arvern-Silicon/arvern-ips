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
// Module Description : Reset value of every register and output after the
//                      power-on reset, after a mid-test reset taken with the
//                      registers loaded and the engine streaming, and after a
//                      reset during a write's ACCESS cycle (the write is lost).
//
// Doc "Register map": CTRL, CLKDIV, STATUS, THRESH, IRQ_EN, RXDATA reset to
// 0, FORMAT to I2S (0x2), MDELEG to MDELEG_RST, INFO holds the build
// parameters; IRQ_PEND reads TX_LOW = 1 (empty FIFO, threshold 0) with a
// transmit path. Doc "Clocks and sample rate": idle outputs (MCLK, SD low,
// BCLK at the BCLK_INV level, LRCK at the right-slot level: high for I2S).
//----------------------------------------------------------------------------

task check_all_reset;
   begin
      chk(i2s_mclk === 1'b0, "MCLK low at reset");
      chk(i2s_bclk === 1'b0, "BCLK at its idle level (low) at reset");
      chk(i2s_lrck === 1'b1, "LRCK at the I2S idle level (high) at reset");
      chk(i2s_sd_o === 1'b0, "SD low at reset");
      chk(irq === 1'b0,      "irq_o low at reset");
      rd(R_INFO,     INFO_VALUE);
      rd(R_CTRL,     32'h0);
      rd(R_CLKDIV,   32'h0);
      rd(R_STATUS,   32'h0);
      rd(R_THRESH,   32'h0);
      rd(R_IRQ_EN,   32'h0);
      rd(R_IRQ_PEND, (TX_EN != 0) ? I_TX_LOW : 32'h0);
      rd(R_TXDATA,   32'h0);
      rd(R_RXDATA,   32'h0);
      rd(R_CMD,      32'h0);
      rd(R_FORMAT,   32'h2);
      rd(R_MDELEG,   MDELEG_RST_WORD);
   end
endtask

initial
   begin
      wait_reset_done(5);
      chk(pclk_en === 1'b0, "pclk_en_o low while idle after reset");

      $display(" ===============================================");
      $display("|   RESET VALUES AFTER POWER-ON RESET           |");
      $display(" ===============================================");
      check_all_reset;

      $display(" ===============================================");
      $display("|   LOAD, STREAM, RESET                         |");
      $display(" ===============================================");
      i2s_setup(2, 3'd1, F_LJ | F_SLOT16, 1'b1);
      wr(R_THRESH, 32'h00050003);
      wr(R_IRQ_EN, 32'h3F);
      if (TX_EN != 0) tx_push_random(3, 1'b0);
      i2s_start(((TX_EN != 0) ? C_TX_ON : 0) | ((RX_EN != 0) ? C_RX_ON : 0));
      wait_frames(2);
      tb_reset_pulse;
      check_all_reset;

      $display(" ===============================================");
      $display("|   RESET DURING A WRITE                        |");
      $display(" ===============================================");
      apb_write(0, MACHINE, R_THRESH, 32'h00070007, SZ_W, OK);
      // the ACCESS cycle is in progress: reset now
      #5 presetn = 1'b0;
      #1 apb_idle;
      repeat (2) @(posedge free_clk);
      #3 presetn = 1'b1;
      dev_defaults;
      repeat (2) @(posedge free_clk);
      #1;
      check_all_reset;

      stimulus_done = 1;
   end
