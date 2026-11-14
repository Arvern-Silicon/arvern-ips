//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    post_reset_edge
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : post_reset_edge.v
// Module Description : A pin already high at reset: IN_EN resets to 0, so
//                      INPUT reads 0 and nothing is raised; enabling the pin
//                      (with IRQ_RISE / IRQ_HIGH already set, or set after)
//                      never reports the step from the held 0 to the high
//                      level as an edge; INPUT then reads the pins; the next
//                      real rising edge is latched. Bus clock gated or forced.
//
// Doc "Register map": IN_EN resets to 0. Doc "Inputs" (Disabled pins):
// "While IN_EN[n]=0 the pin's input stage is held at 0: INPUT[n] reads 0,
// and the pin raises no edge, no level and no wake request." (Enabling a
// pin): "Enabling a pin therefore never reports the step from the held 0 to
// the pin's level, and a pin change after that is reported normally."
//----------------------------------------------------------------------------

integer ii;

task reset_with_pins_high;
   begin
      gpio_ext = 32'hFFFFFFFF;
      cycles(2);
      tb_reset_pulse(8);
      cycles(20);
   end
endtask

initial
   begin
      wait_reset_done(5);

      for (ii = 0; ii < 4; ii = ii + 1)
        begin
           $display(" ===============================================");
           $display("|   CASE %0d: %0s, %0s       |", ii,
                    (ii % 2) ? "modes before IN_EN" : "IN_EN before modes ",
                    (ii < 2) ? "bus clock gated" : "bus clock forced");
           $display(" ===============================================");
           tb_pclk_force = (ii >= 2);
           reset_with_pins_high;
           rd(R_INPUT, 32'h0);                  // disabled pins read 0
           wr(R_IRQ_EN, 32'hFFFFFFFF);
           chk32(irq32, 32'h0, "nothing raised by disabled pins high at reset");
           if (ii % 2)
             begin
                wr(R_IRQ_RISE, 32'hFFFFFFFF);
                inputs_on(32'hFFFFFFFF);
             end
           else
             begin
                inputs_on(32'hFFFFFFFF);
                wr(R_IRQ_RISE, 32'hFFFFFFFF);
             end
           cycles(L_IN + 4);
           rd(R_IRQ_PEND, 32'h0);
           chk32(irq32, 32'h0, "no rising edge from a pin already high at reset");
           rd(R_INPUT, GPIO_MASK);
           pins_set(32'h00000000);
           cycles(L_IN + 3);
           rd(R_IRQ_PEND, 32'h0);
           pins_set(32'hFFFFFFFF);
           cycles(L_IN + 3);
           rd(R_IRQ_PEND, GPIO_MASK);           // the next real rising edge is latched
           chk32(irq32, GPIO_MASK, "irq_o from the first real rising edge");
        end

      // Level mode: reported once the pin has been flushed in, as a level
      reset_with_pins_high;
      wr(R_IRQ_HIGH, 32'hFFFFFFFF);
      rd(R_IRQ_PEND, 32'h0);                    // disabled: no level
      inputs_on(32'hFFFFFFFF);
      rd(R_IRQ_PEND, GPIO_MASK);
      tb_pclk_force = 1'b0;

      cycles(20);
      stimulus_done = 1;
   end
