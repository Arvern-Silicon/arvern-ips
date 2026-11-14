//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    gpio_nr_mask
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpio_nr_mask.v
// Module Description : Register bits above GPIO_NR-1 read 0 and ignore
//                      writes (IN_EN and WAKE_EN included) in every register, and never reach irq_o,
//                      irq_any_o or IRQ_PEND (with GPIO_NR=32 every check
//                      degenerates to the full word).
//
// Doc "Parameters": GPIO_NR "Register bits above GPIO_NR-1 read 0 and ignore
// writes." Doc "Register map": "Bit n is pin n." Doc "Ports": irq_o =
// IRQ_PEND & IRQ_EN, irq_any_o = OR of irq_o.
//----------------------------------------------------------------------------

integer    rr;
reg [31:0] addr;

initial
   begin
      wait_reset_done(5);

      $display(" ===============================================");
      $display("|   ALL-ONES WRITES READ BACK GPIO_MASK         |");
      $display(" ===============================================");
      $display("GPIO_NR=%0d GPIO_MASK=0x%h", GPIO_NR, GPIO_MASK);
      for (rr = 0; rr < 9; rr = rr + 1)
        begin
           case (rr)
             0: addr = R_OUTPUT;
             1: addr = R_OE;
             2: addr = R_IRQ_EN;
             3: addr = R_IRQ_RISE;
             4: addr = R_IRQ_FALL;
             5: addr = R_IRQ_HIGH;
             6: addr = R_IRQ_LOW;
             7: addr = R_IN_EN;
             default: addr = R_WAKE_EN;
           endcase
           wr(addr, 32'hFFFFFFFF);
           rd(addr, GPIO_MASK);
           apb_write(1, MACHINE, addr + 3, 32'hFF,   SZ_B, OK);
           apb_write(1, MACHINE, addr + 2, 32'hFFFF, SZ_H, OK);
           rd(addr, GPIO_MASK);
           wr(addr, 32'h00000000);
           rd(addr, 32'h0);
        end

      $display(" ===============================================");
      $display("|   OUTPUT VIA SET / TGL                        |");
      $display(" ===============================================");
      wr(R_OUT_SET, 32'hFFFFFFFF);
      rd(R_OUTPUT, GPIO_MASK);
      chk32(gpio_o32, GPIO_MASK, "gpio_o after OUT_SET all-ones");
      wr(R_OUT_TGL, 32'hFFFFFFFF);
      rd(R_OUTPUT, 32'h0);
      wr(R_OUT_TGL, 32'hFFFFFFFF);
      rd(R_OUTPUT, GPIO_MASK);
      wr(R_OUT_CLR, 32'hFFFFFFFF);
      rd(R_OUTPUT, 32'h0);
      wr(R_OE, 32'hFFFFFFFF);
      chk32(gpio_oe32, GPIO_MASK, "gpio_oe_o after OE all-ones");
      wr(R_OE, 32'h0);

      $display(" ===============================================");
      $display("|   INPUT AND LEVEL PENDING ABOVE GPIO_NR       |");
      $display(" ===============================================");
      inputs_on(32'hFFFFFFFF);
      wr(R_WAKE_EN, 32'hFFFFFFFF);
      pins_set(32'hFFFFFFFF);
      cycles(L_IN + 2);
      rd(R_INPUT, GPIO_MASK);
      chk(gpio_wake === 1'b0, "gpio_wake_o low once INPUT has caught up (no wake above GPIO_NR)");
      wr(R_IRQ_EN,   32'hFFFFFFFF);
      wr(R_IRQ_HIGH, 32'hFFFFFFFF);
      rd(R_IRQ_PEND, GPIO_MASK);
      chk32(irq32, GPIO_MASK, "irq_o with every pin high and IRQ_HIGH all-ones");
      chk(irq_any === 1'b1,   "irq_any_o with every pin high and IRQ_HIGH all-ones");
      wr(R_IRQ_HIGH, 32'h0);
      // Every real pin high: only the non-existent pins would be "low"
      wr(R_IRQ_LOW,  32'hFFFFFFFF);
      rd(R_IRQ_PEND, 32'h0);
      chk32(irq32, 32'h0,      "irq_o: no low level reported above GPIO_NR");
      chk(irq_any === 1'b0,    "irq_any_o: no low level reported above GPIO_NR");
      pins_set(32'h00000000);
      cycles(L_IN + 2);
      rd(R_IRQ_PEND, GPIO_MASK);
      chk32(irq32, GPIO_MASK,  "irq_o with every pin low and IRQ_LOW all-ones");
      wr(R_IRQ_LOW,  32'h0);
      rd(R_IRQ_PEND, 32'h0);

      $display(" ===============================================");
      $display("|   EDGE PENDING AND W1C ABOVE GPIO_NR          |");
      $display(" ===============================================");
      wr(R_IRQ_RISE, 32'hFFFFFFFF);
      wr(R_IRQ_FALL, 32'hFFFFFFFF);
      pins_set(32'hFFFFFFFF);
      cycles(L_IN + 3);
      pins_set(32'h00000000);
      cycles(L_IN + 3);
      rd(R_IRQ_PEND, GPIO_MASK);
      chk32(irq32, GPIO_MASK, "irq_o after edges on every pin");
      wr(R_IRQ_PEND, ~GPIO_MASK);          // touches only non-existent bits
      rd(R_IRQ_PEND, GPIO_MASK);
      wr(R_IRQ_PEND, 32'hFFFFFFFF);
      rd(R_IRQ_PEND, 32'h0);
      chk(irq_any === 1'b0, "irq_any_o after clearing every pending bit");
      wr(R_IRQ_RISE, 32'h0);
      wr(R_IRQ_FALL, 32'h0);
      wr(R_IRQ_EN,   32'h0);

      $display(" ===============================================");
      $display("|   INFO                                        |");
      $display(" ===============================================");
      rd(R_INFO, INFO_VALUE);

      cycles(20);
      stimulus_done = 1;
   end
