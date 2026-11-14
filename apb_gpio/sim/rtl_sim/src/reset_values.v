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
// Module Description : Reset value of every register and output, after the
//                      power-on reset, after a mid-test reset taken with
//                      every register loaded with a non-reset value, and
//                      after a reset during a write's ACCESS cycle (the
//                      write is lost), and of a latched edge with every
//                      input disabled (input-path clock gate closed).
//
// Doc "Register map": INPUT, OUTPUT, OE, IRQ_EN, IRQ_RISE, IRQ_FALL,
// IRQ_HIGH, IRQ_LOW, IRQ_PEND, IRQ_STAT, IN_EN, WAKE_EN reset to 0; the
// write-only aliases read 0; INFO "Pin mask: bits [GPIO_NR-1:0] set, other
// bits 0"; CFG holds the build constants; MDELEG resets to MDELEG_RST.
// Doc "Ports": gpio_o / gpio_oe_o / gpio_ie_o mirror OUTPUT / OE / IN_EN,
// irq_o = IRQ_PEND & IRQ_EN; gpio_wake_o needs WAKE_EN & IN_EN, so it is low
// at reset. Doc "Parameters": ASYNC_RST_EN=1 is an
// asynchronous reset (outputs clear on assertion, before any edge). Doc
// "Clocks": pclk_en_o stays low during reset; the reset generator (the
// bench gate) requests the bus clock then.
//----------------------------------------------------------------------------

reg [31:0] md_other;

task check_all_reset;
   begin
      chk32(gpio_o32,  32'h0, "gpio_o at reset value");
      chk32(gpio_oe32, 32'h0, "gpio_oe_o at reset value");
      chk32(gpio_ie32, 32'h0, "gpio_ie_o at reset value");
      chk32(irq32,     32'h0, "irq_o at reset value");
      chk(irq_any === 1'b0,   "irq_any_o at reset value");
      chk(gpio_wake === 1'b0, "gpio_wake_o at reset value");
      chk(pready === 1'b1, "pready_o high while idle");
      rd(R_INPUT,    32'h0);
      rd(R_OUTPUT,   32'h0);
      rd(R_OE,       32'h0);
      rd(R_OUT_SET,  32'h0);
      rd(R_OUT_CLR,  32'h0);
      rd(R_OUT_TGL,  32'h0);
      rd(R_IRQ_EN,   32'h0);
      rd(R_IRQ_RISE, 32'h0);
      rd(R_IRQ_FALL, 32'h0);
      rd(R_IRQ_HIGH, 32'h0);
      rd(R_IRQ_LOW,  32'h0);
      rd(R_IRQ_PEND, 32'h0);
      rd(R_INFO,     INFO_VALUE);
      rd(R_IN_EN,    32'h0);
      rd(R_WAKE_EN,  32'h0);
      rd(R_CFG,      CFG_VALUE);
      rd(R_IRQ_STAT, 32'h0);
      rd(R_OE_SET,   32'h0);
      rd(R_OE_CLR,   32'h0);
      rd(R_IRQ_EN_SET, 32'h0);
      rd(R_IRQ_EN_CLR, 32'h0);
      rd(R_MDELEG,   MDELEG_RST_WORD);
   end
endtask

initial
   begin
      wait_reset_done(5);

      $display(" ===============================================");
      $display("|   RESET VALUES AFTER POWER-ON RESET           |");
      $display(" ===============================================");
      check_all_reset;

      $display(" ===============================================");
      $display("|   LOAD NON-RESET VALUES                       |");
      $display(" ===============================================");
      inputs_on(32'hFFFFFFFF);
      wr(R_WAKE_EN,  32'hFFFFFFFF);
      wr(R_OUTPUT,   32'hA5A5A5A5);
      wr(R_OE,       32'hFFFFFFFF);
      wr(R_IRQ_EN,   32'hFFFFFFFF);
      wr(R_IRQ_RISE, 32'hFFFFFFFF);
      wr(R_IRQ_FALL, 32'hFFFFFFFF);
      wr(R_IRQ_HIGH, 32'h0F0F0F0F);
      wr(R_IRQ_LOW,  32'hF0F0F0F0);
      md_other = (MDELEG_RST_WORD != 32'h00000005) ? 32'h00000005 : 32'h0000010F;   // storable, not the reset value
      wr(R_MDELEG,   md_other);
      rd(R_MDELEG,   md_other);
      pins_set(32'hFFFFFFFF);
      cycles(L_IN + 4);
      pins_set(32'h00000000);              // INPUT reset value is checked with the pins low
      cycles(L_IN + 4);
      rd(R_OUTPUT,   32'hA5A5A5A5 & GPIO_MASK);
      rd(R_IRQ_PEND, GPIO_MASK);           // rise + fall latched on every pin
      chk32(irq32, GPIO_MASK, "irq_o before the reset");

      $display(" ===============================================");
      $display("|   MID-TEST RESET                              |");
      $display(" ===============================================");
      @(posedge free_clk);
      #10;
      presetn = 1'b0;
      #2;
      if (ASYNC_RST_EN != 0)
        begin
           chk32(gpio_o32,  32'h0, "async reset: gpio_o clears before any edge");
           chk32(gpio_oe32, 32'h0, "async reset: gpio_oe_o clears before any edge");
           chk32(irq32,     32'h0, "async reset: irq_o clears before any edge");
           chk(irq_any === 1'b0,   "async reset: irq_any_o clears before any edge");
           chk(gpio_wake === 1'b0, "async reset: gpio_wake_o clears before any edge");
        end
      repeat (2) @(negedge free_clk);
      chk(pclk_en === 1'b0, "pclk_en_o low during reset");
      repeat (3) @(posedge free_clk);
      #1;
      chk(pclk_en === 1'b0, "pclk_en_o low during reset");
      chk32(gpio_o32,  32'h0, "gpio_o cleared during reset");
      chk32(gpio_oe32, 32'h0, "gpio_oe_o cleared during reset");
      chk32(irq32,     32'h0, "irq_o cleared during reset");
      chk(irq_any === 1'b0,   "irq_any_o cleared during reset");
      @(posedge free_clk);
      #10;
      presetn = 1'b1;
      apb_idle;
      cycles(5);

      $display(" ===============================================");
      $display("|   RESET VALUES AFTER MID-TEST RESET           |");
      $display(" ===============================================");
      check_all_reset;

      // Writes to the read-only and write-only registers leave reset values
      wr(R_INPUT, 32'hFFFFFFFF);
      wr(R_INFO,  32'hFFFFFFFF);
      rd(R_INFO,  INFO_VALUE);
      rd(R_INPUT, 32'h0);

      $display(" ===============================================");
      $display("|   RESET DURING A WRITE'S ACCESS CYCLE         |");
      $display(" ===============================================");
      wr(R_OE, 32'hFFFFFFFF);
      apb_write(0, MACHINE, R_OUTPUT, 32'hFFFFFFFF, SZ_W, OK);   // returns in ACCESS
      #10 presetn = 1'b0;
      repeat (3) @(posedge free_clk);
      #10 presetn = 1'b1;
      apb_idle;
      cycles(5);
      check_all_reset;

      $display(" ===============================================");
      $display("|   RESET CLEARS A LATCHED EDGE, INPUTS OFF     |");
      $display(" ===============================================");
      // The latched edge survives clearing IN_EN; with every input off the
      // input-path clock gate is closed, and the reset must still clear it.
      wr(R_IN_EN,    pbit(0));
      pins_set(32'h0);
      cycles(L_IN + 3);
      wr(R_IRQ_RISE, pbit(0));
      pins_set(32'hFFFFFFFF);
      cycles(L_IN + 3);
      rd(R_IRQ_PEND, pbit(0));
      wr(R_IRQ_RISE, 32'h0);
      wr(R_IN_EN,    32'h0);
      cycles(2*L_IN + 4);
      rd(R_IRQ_PEND, pbit(0));
      tb_reset_pulse(3);
      cycles(3);
      rd(R_IRQ_PEND, 32'h0);
      pins_set(32'h0);

      cycles(20);
      stimulus_done = 1;
   end
