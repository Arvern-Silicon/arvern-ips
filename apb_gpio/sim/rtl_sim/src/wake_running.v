//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    wake_running
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : wake_running.v
// Module Description : gpio_wake_o with the clock running: with no mode bit
//                      set, every change of a wake-enabled, enabled pin
//                      raises it at once (before any clock edge) and it drops
//                      on pclk_aon edge L, when the input register has caught
//                      up -- rising and falling, on a spread of pins; with
//                      IRQ_RISE and IRQ_HIGH set only the rising change
//                      pulses; no pulse for a pin without WAKE_EN or without
//                      IN_EN; then random pin activity checked every cycle
//                      against the reference model. (wake_polarity covers
//                      every mode set.)
//
// Doc "Wake": the wake formula, with its rise / fall mode terms; "While the
// clock runs, gpio_wake_o also pulses for a few cycles after every such
// change." "gpio_wake_o is a combinational function of the pads". Doc
// "Inputs": INPUT follows the pin L pclk_aon_i edges after it changes.
//----------------------------------------------------------------------------

integer    ii;
integer    kk;
integer    p;
integer    bad;

// Flip pin pp; check gpio_wake_o: 'expect_pulse' -> high at once, low from
// edge L; otherwise low throughout.
task flip_check;
   input integer pp;
   input         expect_pulse;
   begin
      @(posedge free_clk);
      #10;
      gpio_ext = gpio_ext ^ pbit(pp);
      #1;
      if (expect_pulse)
        chk(gpio_wake === 1'b1, "wake pulse starts with the pin change (no clock edge)");
      else
        chk(gpio_wake === 1'b0, "no wake pulse");
      for (kk = 1; kk <= L_IN + 2; kk = kk + 1)
        begin
           @(posedge free_clk);
           #1;
           if (expect_pulse && (kk < L_IN))
             chk(gpio_wake === 1'b1, "wake pulse held until INPUT catches up");
           else
             chk(gpio_wake === 1'b0, "wake pulse over once INPUT caught up (edge L)");
        end
   end
endtask

initial
   begin
      wait_reset_done(5);
      gpio_ext = 32'h0;

      $display(" ===============================================");
      $display("|   NO MODE SET: PULSE ON EVERY CHANGE          |");
      $display(" ===============================================");
      inputs_on(32'hFFFFFFFF);
      wr(R_WAKE_EN, 32'hFFFFFFFF);
      for (ii = 0; ii < PICK_PIN_NR; ii = ii + 1)
        begin
           p = pick_pin(ii);
           flip_check(p, 1'b1);              // rising
           flip_check(p, 1'b1);              // falling
        end
      // Rising-direction modes: only the rising change pulses
      wr(R_IRQ_RISE, 32'hFFFFFFFF);
      wr(R_IRQ_HIGH, 32'hFFFFFFFF);
      flip_check(pick_pin(4), 1'b1);              // rising
      flip_check(pick_pin(4), 1'b0);              // falling
      wr(R_IRQ_RISE, 32'h0);
      wr(R_IRQ_HIGH, 32'h0);

      $display(" ===============================================");
      $display("|   NO PULSE WITHOUT WAKE_EN OR IN_EN           |");
      $display(" ===============================================");
      p = pick_pin(6);
      wr(R_WAKE_EN, GPIO_MASK & ~pbit(p));
      flip_check(p, 1'b0);
      flip_check(p, 1'b0);
      wr(R_WAKE_EN, 32'hFFFFFFFF);
      wr(R_IN_EN,   GPIO_MASK & ~pbit(p));
      cycles(2);
      flip_check(p, 1'b0);
      flip_check(p, 1'b0);
      inputs_on(32'hFFFFFFFF);

      $display(" ===============================================");
      $display("|   RANDOM PINS AGAINST THE MODEL               |");
      $display(" ===============================================");
      wr(R_IRQ_RISE, 32'h55555555);
      wr(R_IRQ_FALL, 32'h33333333);
      wr(R_IRQ_EN,   32'hFFFFFFFF);
      wr(R_WAKE_EN,  32'h0F0F0F0F | pbit(0));
      cycles(2);
      model_check_en = 1'b1;
      bad = m_errors;
      for (ii = 0; ii < 200; ii = ii + 1)
        begin
           repeat (1 + ($urandom % 4)) @(posedge free_clk);
           #10;
           if (($urandom % 4) == 0)
             gpio_ext = $urandom;
           else
             gpio_ext = gpio_ext ^ pbit($urandom % GPIO_NR);
        end
      cycles(L_IN + 3);
      model_check_en = 1'b0;
      $display("model mismatches: %0d", m_errors - bad);

      cycles(20);
      stimulus_done = 1;
   end
