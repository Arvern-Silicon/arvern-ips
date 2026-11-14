//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    irq_w1c_race
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : irq_w1c_race.v
// Module Description : A W1C of an already-pending bit landing one edge
//                      before, on, and one edge after the edge that latches a
//                      new event on that pin: set / set / cleared. On the
//                      same edge irq_o must not even blink. Rising and
//                      falling edges; an all-ones W1C clears the other
//                      pending bits but not the racing one.
//
// Doc "Interrupts" (Edges): "A write of 1 in the same cycle as a new edge on
// that pin leaves the bit set: the new event is not lost." Handler sequence:
// "The write takes effect at the end of its ACCESS cycle, and irq_o drops on
// the same clock edge."
// The latching edge K (edges after the pin change) is measured first, so the
// three cases are placed on the DUT's own latch edge, not on an assumed one.
//----------------------------------------------------------------------------

integer    kk;
integer    K;
integer    dd;
integer    base;
integer    p;
integer    q;
integer    c;
reg [31:0] new_pins;

// Pin pp to 'level'; return in K the edge on which irq_o[pp] rose (0 = never)
task measure_k;
   input integer pp;
   input         level;
   begin
      K = 0;
      @(posedge free_clk);
      #10;
      gpio_ext = level ? (gpio_ext | pbit(pp)) : (gpio_ext & ~pbit(pp));
      for (kk = 1; kk <= L_IN + 4; kk = kk + 1)
        begin
           @(posedge free_clk);
           #1;
           if ((K == 0) && ((irq32 & pbit(pp)) != 0))
             K = kk;
        end
   end
endtask

// With IRQ_PEND[pp] already set: move pin pp to 'level' on edge base+3 (+#10)
// and end a W1C of 'bits' on edge base+3+K+d.
task race;
   input integer pp;
   input         level;
   input integer d;
   input  [31:0] bits;
   begin
      @(posedge free_clk);
      #1;
      base     = free_cnt;
      new_pins = level ? (gpio_ext | pbit(pp)) : (gpio_ext & ~pbit(pp));
      fork
         begin
            wait (free_cnt == base + 3);
            #10;
            gpio_ext = new_pins;
         end
         begin
            wait (free_cnt == base + 3 + K + d - 2);
            #1;
            apb_write(0, MACHINE, R_IRQ_PEND, bits, SZ_W, OK);
         end
         begin
            // irq_o[pp] seen at every falling edge: c = edges since the pin change edge
            repeat (3 + K + 4)
              begin
                 @(negedge free_clk);
                 c = free_cnt - base - 3;
                 if (c >= 0)
                   begin
                      if (d == 0)
                        chk((irq32 & pbit(pp)) != 0, "same-edge W1C: irq_o must stay high");
                      else if (d < 0)
                        chk(((irq32 & pbit(pp)) != 0) === (c != K - 1), "W1C one edge early: irq_o low for one cycle only");
                      else
                        chk(((irq32 & pbit(pp)) != 0) === (c < K + 1), "W1C one edge late: irq_o drops on the W1C edge");
                   end
              end
         end
      join
      apb_flush;
      cycles(L_IN + 3);
   end
endtask

// Make IRQ_PEND[pp] set by a rising edge, pin back low (no falling mode)
task preset_pending_rise;
   input integer pp;
   begin
      pins_set(gpio_ext & ~pbit(pp));
      cycles(L_IN + 3);
      pins_set(gpio_ext | pbit(pp));
      cycles(L_IN + 3);
      pins_set(gpio_ext & ~pbit(pp));
      cycles(L_IN + 3);
   end
endtask

initial
   begin
      wait_reset_done(5);
      gpio_ext = 32'h0;
      inputs_on(32'hFFFFFFFF);
      p = pick_pin(4);
      q = pick_pin(2);

      $display(" ===============================================");
      $display("|   MEASURE THE LATCHING EDGE                   |");
      $display(" ===============================================");
      wr(R_IRQ_RISE, pbit(p));
      wr(R_IRQ_EN,   pbit(p));
      cycles(L_IN + 3);
      measure_k(p, 1'b1);
      $display("rising edge on pin %0d latched on edge K=%0d (expected %0d)", p, K, L_IN + 1);
      chk(K == L_IN + 1, "edge latched on edge L+1 after the pin change");
      if (K == 0)
        begin
           $display("ERROR: no latching edge measured, race cases not run %t ns", $time);
           error = error + 1;
        end
      else
        begin
           for (dd = -1; dd <= 1; dd = dd + 1)
             begin
                $display(" ===============================================");
                $display("|   RISING EDGE, W1C AT K%0d                       |", dd);
                $display(" ===============================================");
                preset_pending_rise(p);
                rd(R_IRQ_PEND, pbit(p));
                race(p, 1'b1, dd, pbit(p));
                rd(R_IRQ_PEND, (dd <= 0) ? pbit(p) : 32'h0);
                wr(R_IRQ_PEND, pbit(p));
                rd(R_IRQ_PEND, 32'h0);
             end

           $display(" ===============================================");
           $display("|   FALLING EDGE, SAME-EDGE W1C                 |");
           $display(" ===============================================");
           preset_pending_rise(p);
           pins_set(gpio_ext | pbit(p));
           cycles(L_IN + 3);
           wr(R_IRQ_FALL, pbit(p));                // pin already high: no event
           wr(R_IRQ_RISE, 32'h0);
           rd(R_IRQ_PEND, pbit(p));                // the rise latched by preset_pending_rise
           race(p, 1'b0, 0, pbit(p));
           rd(R_IRQ_PEND, pbit(p));
           wr(R_IRQ_PEND, pbit(p));
           rd(R_IRQ_PEND, 32'h0);
           wr(R_IRQ_RISE, pbit(p));
           wr(R_IRQ_FALL, 32'h0);

           if (q != p)
             begin
                $display(" ===============================================");
                $display("|   ALL-ONES W1C RACING ONE PIN                 |");
                $display(" ===============================================");
                wr(R_IRQ_RISE, pbit(p) | pbit(q));
                wr(R_IRQ_EN,   pbit(p) | pbit(q));
                preset_pending_rise(q);
                preset_pending_rise(p);
                rd(R_IRQ_PEND, pbit(p) | pbit(q));
                race(p, 1'b1, 0, 32'hFFFFFFFF);
                rd(R_IRQ_PEND, pbit(p));
                chk32(irq32, pbit(p), "irq_o after an all-ones W1C racing one pin");
             end
        end

      cycles(20);
      stimulus_done = 1;
   end
