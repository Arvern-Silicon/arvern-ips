//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    irq_mode_no_event
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : irq_mode_no_event.v
// Module Description : Writing a mode register creates no event: IRQ_RISE
//                      turned on with the pin already high (and IRQ_FALL
//                      with the pin low) sets nothing, with or without
//                      another mode bit set and with the bus clock gated or
//                      forced; toggling the mode bit does not either; the
//                      next real edge does.
//
// Doc "Interrupts": "Writing a mode register does not create an event:
// turning on IRQ_RISE while a pin is already high sets nothing; the next
// rising edge does." The pins are enabled (IN_EN) and stable for many cycles
// before each mode write.
//----------------------------------------------------------------------------

integer    ii;
integer    p;
integer    q;
reg [31:0] keep;

task no_event_case;
   input integer pp;
   input         use_keep;         // 1: another pin's mode bit already set
   begin
      keep = (use_keep && (GPIO_NR > 1)) ? pbit(pp + 1) : 32'h0;
      wr(R_IRQ_HIGH, keep);            // a level mode on a pin held low: never pending
      wr(R_IRQ_EN, pbit(pp));
      cycles(2*L_IN + 3);

      // IRQ_RISE with the pin already high
      pins_set(gpio_ext | pbit(pp));
      cycles(L_IN + 4);
      wr(R_IRQ_RISE, pbit(pp));
      cycles(2*L_IN + 4);
      rd(R_IRQ_PEND, 32'h0);
      chk((irq32 & pbit(pp)) == 0, "IRQ_RISE turned on with the pin high: no irq_o");
      wr(R_IRQ_RISE, 32'h0);           // off / on again: still nothing
      wr(R_IRQ_RISE, pbit(pp));
      cycles(2*L_IN + 4);
      rd(R_IRQ_PEND, 32'h0);
      pins_set(gpio_ext & ~pbit(pp));
      cycles(L_IN + 3);
      rd(R_IRQ_PEND, 32'h0);
      pins_set(gpio_ext | pbit(pp));   // the next rising edge sets it
      cycles(L_IN + 3);
      rd(R_IRQ_PEND, pbit(pp));
      wr(R_IRQ_PEND, pbit(pp));
      wr(R_IRQ_RISE, 32'h0);

      // IRQ_FALL with the pin already low
      pins_set(gpio_ext & ~pbit(pp));
      cycles(L_IN + 4);
      wr(R_IRQ_FALL, pbit(pp));
      cycles(2*L_IN + 4);
      rd(R_IRQ_PEND, 32'h0);
      pins_set(gpio_ext | pbit(pp));
      cycles(L_IN + 3);
      rd(R_IRQ_PEND, 32'h0);
      pins_set(gpio_ext & ~pbit(pp));  // the next falling edge sets it
      cycles(L_IN + 3);
      rd(R_IRQ_PEND, pbit(pp));
      wr(R_IRQ_PEND, pbit(pp));
      wr(R_IRQ_FALL, 32'h0);

      // IRQ_RISE and IRQ_FALL together on a high pin
      pins_set(gpio_ext | pbit(pp));
      cycles(L_IN + 4);
      wr(R_IRQ_FALL, pbit(pp));
      wr(R_IRQ_RISE, pbit(pp));
      cycles(2*L_IN + 4);
      rd(R_IRQ_PEND, 32'h0);
      wr(R_IRQ_RISE, 32'h0);
      wr(R_IRQ_FALL, 32'h0);
      wr(R_IRQ_HIGH, 32'h0);
      pins_set(gpio_ext & ~pbit(pp));
      cycles(L_IN + 4);
   end
endtask

initial
   begin
      wait_reset_done(5);
      gpio_ext      = 32'h0;
      inputs_on(32'hFFFFFFFF);

      for (ii = 0; ii < PICK_PIN_NR; ii = ii + 1)
        begin
           p = pick_pin(ii);
           $display(" ===============================================");
           tb_pclk_force = ii % 2;
           $display("|   PIN %2d, ONLY MODE BIT, bus clock forced=%0d   |", p, tb_pclk_force);
           $display(" ===============================================");
           no_event_case(p, 1'b0);
           $display(" ===============================================");
           $display("|   PIN %2d, ANOTHER MODE BIT SET               |", p);
           $display(" ===============================================");
           no_event_case(p, 1'b1);
        end

      cycles(20);
      stimulus_done = 1;
   end
