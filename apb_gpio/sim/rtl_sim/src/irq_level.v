//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    irq_level
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : irq_level.v
// Module Description : High and low level conditions: live in IRQ_PEND,
//                      not cleared by W1C, gone when the pin changes or the
//                      mode bit is cleared (not when IRQ_EN is cleared),
//                      OR-ed with a latched edge, both modes at once.
//
// Doc "Interrupts" (Levels): "IRQ_HIGH[n]=1 and the pin high, or IRQ_LOW[n]=1
// and the pin low, make IRQ_PEND[n] read 1 for as long as the condition
// holds. A level is not latched: writing 1 does not clear it, and it
// disappears when the pin changes or the mode bit is cleared."
// "IRQ_PEND[n] reads the OR of the latched edge bit and the live level
// condition." "IRQ_EN only gates them onto irq_o[n] and irq_any_o."
// Timing: a mode-bit write takes effect at the end of its ACCESS cycle, so a
// level appears / disappears on that edge exactly (pins enabled and settled).
//----------------------------------------------------------------------------

integer    ii;
integer    p;

// Set a level mode bit; check irq_o[pp] before / after
task mode_set_level;
   input [31:0] addr;
   input [31:0] data;
   input integer pp;
   input        irq_after;
   begin
      apb_write(0, MACHINE, addr, data, SZ_W, OK);
      @(negedge free_clk);
      chk((irq32 & pbit(pp)) == 0, "irq_o still low during the mode-write ACCESS cycle");
      @(posedge free_clk);
      #1;
      chk(((irq32 & pbit(pp)) != 0) === irq_after, "level on irq_o from the edge ending the mode write");
   end
endtask

// Clear a level mode bit: the level goes on the write's edge
task mode_clr_level;
   input [31:0] addr;
   input integer pp;
   begin
      apb_write(0, MACHINE, addr, 32'h0, SZ_W, OK);
      @(negedge free_clk);
      chk((irq32 & pbit(pp)) != 0, "level still on irq_o during the mode-clear ACCESS cycle");
      @(posedge free_clk);
      #1;
      chk((irq32 & pbit(pp)) == 0, "level gone from irq_o on the edge ending the mode clear");
   end
endtask

initial
   begin
      wait_reset_done(5);
      gpio_ext = 32'h0;
      inputs_on(32'hFFFFFFFF);

      for (ii = 0; ii < PICK_PIN_NR; ii = ii + 1)
        begin
           p     = pick_pin(ii);
           tb_pclk_force = ii % 2;                 // bus clock gated or forced: same result
           $display(" ===============================================");
           $display("|   PIN %2d                                      |", p);
           $display(" ===============================================");
           gpio_ext = 32'h0;
           wr(R_IRQ_EN,   pbit(p));
           cycles(L_IN + 3);
           wr(R_IRQ_PEND, 32'hFFFFFFFF);
           rd(R_IRQ_PEND, 32'h0);

           // High level
           pins_set(gpio_ext | pbit(p));
           cycles(L_IN + 2);
           rd(R_IRQ_PEND, 32'h0);                  // IRQ_HIGH not set yet
           mode_set_level(R_IRQ_HIGH, pbit(p), p, 1'b1);
           rd(R_IRQ_PEND, pbit(p));
           wr(R_IRQ_PEND, pbit(p));                // W1C does not clear a level
           rd(R_IRQ_PEND, pbit(p));
           chk((irq32 & pbit(p)) != 0, "high level survives a W1C");
           wr(R_IRQ_EN, 32'h0);                    // IRQ_EN gates irq_o only
           rd(R_IRQ_PEND, pbit(p));
           chk(irq32 == 32'h0,   "irq_o gated by IRQ_EN=0");
           chk(irq_any === 1'b0, "irq_any_o gated by IRQ_EN=0");
           wr(R_IRQ_EN, pbit(p));
           chk((irq32 & pbit(p)) != 0, "irq_o back with IRQ_EN=1");
           pins_set(gpio_ext & ~pbit(p));          // the pin changes: level gone
           cycles(L_IN + 1);
           chk(irq32 == 32'h0, "high level gone with the pin");
           rd(R_IRQ_PEND, 32'h0);
           pins_set(gpio_ext | pbit(p));
           cycles(L_IN + 1);
           rd(R_IRQ_PEND, pbit(p));                // back with the pin, nothing latched
           mode_clr_level(R_IRQ_HIGH, p);          // mode bit cleared: level gone
           rd(R_IRQ_PEND, 32'h0);

           // Low level
           pins_set(gpio_ext & ~pbit(p));
           cycles(L_IN + 2);
           rd(R_IRQ_PEND, 32'h0);
           mode_set_level(R_IRQ_LOW, pbit(p), p, 1'b1);
           rd(R_IRQ_PEND, pbit(p));
           wr(R_IRQ_PEND, pbit(p));
           rd(R_IRQ_PEND, pbit(p));
           pins_set(gpio_ext | pbit(p));
           cycles(L_IN + 1);
           chk(irq32 == 32'h0, "low level gone with the pin");
           rd(R_IRQ_PEND, 32'h0);
           pins_set(gpio_ext & ~pbit(p));
           cycles(L_IN + 1);
           rd(R_IRQ_PEND, pbit(p));
           mode_clr_level(R_IRQ_LOW, p);
           rd(R_IRQ_PEND, 32'h0);

           // Both levels: pending whatever the pin
           wr(R_IRQ_HIGH, pbit(p));
           wr(R_IRQ_LOW,  pbit(p));
           cycles(L_IN + 2);
           rd(R_IRQ_PEND, pbit(p));
           pins_set(gpio_ext | pbit(p));
           cycles(L_IN + 2);
           rd(R_IRQ_PEND, pbit(p));
           chk((irq32 & pbit(p)) != 0, "high+low levels pending with the pin high");
           pins_set(gpio_ext & ~pbit(p));
           cycles(L_IN + 2);
           rd(R_IRQ_PEND, pbit(p));
           wr(R_IRQ_HIGH, 32'h0);
           wr(R_IRQ_LOW,  32'h0);
           rd(R_IRQ_PEND, 32'h0);

           // Latched edge OR level: the latched part stays when the level goes
           wr(R_IRQ_RISE, pbit(p));
           wr(R_IRQ_HIGH, pbit(p));
           cycles(L_IN + 3);
           pins_set(gpio_ext | pbit(p));
           cycles(L_IN + 3);
           rd(R_IRQ_PEND, pbit(p));
           pins_set(gpio_ext & ~pbit(p));
           cycles(L_IN + 3);
           rd(R_IRQ_PEND, pbit(p));                // level gone, latched rise remains
           wr(R_IRQ_PEND, pbit(p));
           rd(R_IRQ_PEND, 32'h0);                  // W1C clears it, no level left
           wr(R_IRQ_RISE, 32'h0);
           wr(R_IRQ_HIGH, 32'h0);
        end
      tb_pclk_force = 1'b0;

      cycles(20);
      stimulus_done = 1;
   end
