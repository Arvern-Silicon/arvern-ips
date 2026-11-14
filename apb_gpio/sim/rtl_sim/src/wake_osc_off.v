//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    wake_osc_off
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : wake_osc_off.v
// Module Description : gpio_wake_o with the oscillator off (bench
//                      tb_osc_off: pclk_aon AND pclk stopped).
//   1. A change on a pin with WAKE_EN and IN_EN raises gpio_wake_o with no
//      clock edge; the line stays up; it falls again if the pin returns to
//      the sampled value; irq_o does not move without a clock.
//   2. A pin with WAKE_EN but IN_EN=0, and a pin with IN_EN but WAKE_EN=0,
//      raise nothing.
//   3. Restarting the oscillator: gpio_wake_o drops on pclk_aon edge L (the
//      input register has caught up) and the change is then latched as a
//      rising edge (edge L+1).
//   4. The wake follows the modes: a falling change on a rising-edge pin
//      raises no wake request, the oscillator stays off, and once it is
//      restarted the change reports nothing.
//   5. A pin whose stage is still flushing (oscillator stopped on the edge
//      that set its IN_EN bit) does not request a wake, whatever it does;
//      once the clock runs it finishes the flush without reporting its step.
//
// Doc "Wake": the wake formula (a change in a direction the pin's modes
// report; pin p has IRQ_RISE, so its rising change wakes). "When the oscillator stops, the input register
// keeps the last sampled value. A change on a pin with WAKE_EN and IN_EN set
// then makes the pin differ from it and raises gpio_wake_o with no clock.
// Once the clock runs again the change crosses the input stage, the input
// register catches up, gpio_wake_o drops, and the change is reported like any
// other ... A pin whose stage is still flushing (see Inputs) does not request
// a wake." "A pin set up for a rising edge does not wake on a falling one".
// Cases 2 and 5 need four distinct pins (GPIO_NR >= 4); they are skipped
// below that.
//----------------------------------------------------------------------------

integer    kk;
integer    p;
integer    r;
integer    s;
integer    t;
integer    a0;
integer    bad;
reg        four;

initial
   begin
      wait_reset_done(5);
      gpio_ext = 32'h0;
      p    = pick_pin(3);
      r    = (p + 1) % GPIO_NR;
      s    = (p + 2) % GPIO_NR;
      t    = (p + 3) % GPIO_NR;
      four = (GPIO_NR >= 4);

      wr(R_IRQ_RISE, pbit(p) | (four ? pbit(t) : 32'h0));
      wr(R_IRQ_EN,   pbit(p) | (four ? pbit(t) : 32'h0));
      wr(R_WAKE_EN,  pbit(p) | (four ? (pbit(r) | pbit(t)) : 32'h0));
      inputs_on(pbit(p) | (four ? pbit(s) : 32'h0));
      cycles(5);
      chk(gpio_wake === 1'b0, "no wake request with the pins settled");

      $display(" ===============================================");
      $display("|   1/2. OSCILLATOR OFF, PIN CHANGES            |");
      $display(" ===============================================");
      osc_stop;
      a0 = aon_cnt;
      if (four)
        begin
           @(posedge free_clk); #10;
           gpio_ext = gpio_ext | pbit(r);      // WAKE_EN, IN_EN=0
           #1;
           chk(gpio_wake === 1'b0, "no wake from a disabled (IN_EN=0) pin");
           @(posedge free_clk); #10;
           gpio_ext = gpio_ext | pbit(s);      // IN_EN, WAKE_EN=0
           #1;
           chk(gpio_wake === 1'b0, "no wake from a pin without WAKE_EN");
           cycles(3);
           chk(gpio_wake === 1'b0, "still no wake request");
        end
      @(posedge free_clk); #10;
      gpio_ext = gpio_ext | pbit(p);
      #1;
      chk(gpio_wake === 1'b1, "wake raised with no clock by a WAKE_EN & IN_EN pin");
      bad = 0;
      repeat (10)
        begin
           @(negedge free_clk);
           if (gpio_wake !== 1'b1) bad = bad + 1;
        end
      chk(bad == 0, "wake request held while the oscillator is off");
      chk(aon_cnt == a0, "no pclk_aon edge while the oscillator is off");
      chk((irq32 & pbit(p)) == 0, "no irq_o without a clock");
      @(posedge free_clk); #10;
      gpio_ext = gpio_ext & ~pbit(p);         // back to the sampled value
      #1;
      chk(gpio_wake === 1'b0, "wake falls when the pin returns to the sampled value");
      @(posedge free_clk); #10;
      gpio_ext = gpio_ext | pbit(p);
      #1;
      chk(gpio_wake === 1'b1, "wake raised again");

      $display(" ===============================================");
      $display("|   3. OSCILLATOR BACK: WAKE DROPS, EDGE LATCHED|");
      $display(" ===============================================");
      osc_start;
      for (kk = 1; kk <= L_IN + 2; kk = kk + 1)
        begin
           @(posedge free_clk);
           #1;
           if (kk < L_IN)
             chk(gpio_wake === 1'b1, "wake held until the input register catches up");
           else
             chk(gpio_wake === 1'b0, "wake dropped once the input register caught up (edge L)");
        end
      chk(aon_cnt == a0 + L_IN + 2, "pclk_aon running again");
      chk((irq32 & pbit(p)) != 0, "the change reported as a rising edge");
      rd(R_IRQ_PEND, pbit(p));
      rd(R_INPUT, (pbit(p) | (four ? pbit(s) : 32'h0)) & GPIO_MASK);
      wr(R_IRQ_PEND, pbit(p));

      $display(" ===============================================");
      $display("|   4. A FALLING CHANGE DOES NOT WAKE           |");
      $display(" ===============================================");
      osc_stop;
      @(posedge free_clk); #10;
      gpio_ext = gpio_ext & ~pbit(p);
      #1;
      chk(gpio_wake === 1'b0, "falling change on a rising-edge pin: no wake");
      bad = 0;
      repeat (5)
        begin
           @(negedge free_clk);
           if (gpio_wake !== 1'b0) bad = bad + 1;
        end
      chk(bad == 0, "still no wake while the oscillator is off");
      osc_start;
      cycles(L_IN + 3);
      chk(gpio_wake === 1'b0, "wake dropped after the restart");
      rd(R_IRQ_PEND, 32'h0);                  // the falling change reports nothing

      if (four)
        begin
           $display(" ===============================================");
           $display("|   5. A FLUSHING PIN DOES NOT WAKE             |");
           $display(" ===============================================");
           pins_set(gpio_ext | pbit(t));      // t: WAKE_EN, IRQ_RISE, still disabled
           cycles(L_IN + 3);
           chk(gpio_wake === 1'b0, "disabled pin high: no wake");
           apb_write(0, MACHINE, R_IN_EN, pbit(p) | pbit(s) | pbit(t), SZ_W, OK);
           osc_stop;                          // last clock edge: the one ending the write
           a0 = aon_cnt;
           #1;
           chk(gpio_wake === 1'b0, "flushing pin differing from INPUT (0): no wake");
           bad = 0;
           repeat (3)
             begin
                @(posedge free_clk); #10;
                gpio_ext = gpio_ext ^ pbit(t);
                #1;
                if (gpio_wake !== 1'b0) bad = bad + 1;
             end
           chk(bad == 0, "flushing pin changing: no wake");
           chk(aon_cnt == a0, "oscillator stopped during the flush");
           @(posedge free_clk); #10;
           gpio_ext = gpio_ext | pbit(t);
           osc_start;
           cycles(2*L_IN + 4);
           chk(gpio_wake === 1'b0, "no wake once the flushed pin matches INPUT");
           rd(R_INPUT, (pbit(p) | pbit(s) | pbit(t)) & GPIO_MASK & gpio_ext);
           rd(R_IRQ_PEND, 32'h0);             // the flushed-in step is not an edge
           chk((irq32 & pbit(t)) == 0, "no irq_o from the flushed-in step");
        end
      else
        $display("GPIO_NR<4: cases 2 and 5 not run");

      cycles(20);
      stimulus_done = 1;
   end
