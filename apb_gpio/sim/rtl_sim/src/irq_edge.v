//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    irq_edge
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : irq_edge.v
// Module Description : Rising, falling and both-edge latching into IRQ_PEND,
//                      per pin, with W1C clear; latched bits survive the pin
//                      returning and the mode bit being cleared; writing 0
//                      or writing other bits clears nothing; a one-cycle
//                      pulse is seen by both edge modes; edge-latch latency.
//
// Doc "Interrupts" (Edges): "A rising edge with IRQ_RISE[n]=1, or a falling
// edge with IRQ_FALL[n]=1, sets the latched bit of IRQ_PEND[n]. It stays set
// until software writes 1 to it." Handler sequence: "The write takes effect
// at the end of its ACCESS cycle, and irq_o drops on the same clock edge."
// Doc "Inputs": "Edge detection compares the input register with its value
// one cycle earlier, so a pulse is seen only if it stays stable for at least
// one pclk_i period at the sampling point".
// Latency: the input register changes L edges after the pin (3 / 1) and the
// edge is compared with the previous value, so the latched bit is expected
// on edge L+1 -- this test's reading of the two sentences above; it is
// measured and asserted here, and irq_w1c_race uses the measured value.
//----------------------------------------------------------------------------

integer    ii;
integer    kk;
integer    p;
integer    lat;

// Move pin pp and return the edge index on which irq_o[pp] rose (0 = never)
task pin_edge_lat;
   input integer pp;
   input         level;
   begin
      lat = 0;
      @(posedge free_clk);
      #10;
      gpio_ext = level ? (gpio_ext | pbit(pp)) : (gpio_ext & ~pbit(pp));
      for (kk = 1; kk <= L_IN + 4; kk = kk + 1)
        begin
           @(posedge free_clk);
           #1;
           if ((lat == 0) && ((irq32 & pbit(pp)) != 0))
             lat = kk;
        end
   end
endtask

// W1C with exact irq_o timing
task w1c_exact;
   input [31:0] bits;
   input [31:0] irq_before;
   input [31:0] irq_after;
   begin
      apb_write(0, MACHINE, R_IRQ_PEND, bits, SZ_W, OK);
      @(negedge free_clk);
      chk32(irq32, irq_before, "irq_o unchanged during the W1C ACCESS cycle");
      @(posedge free_clk);
      #1;
      chk32(irq32, irq_after,  "irq_o dropped on the edge ending the W1C ACCESS cycle");
   end
endtask

initial
   begin
      wait_reset_done(5);
      gpio_ext = 32'h0;
      inputs_on(32'hFFFFFFFF);                     // doc "Inputs": only enabled pins raise events

      for (ii = 0; ii < PICK_PIN_NR; ii = ii + 1)
        begin
           p = pick_pin(ii);
           $display(" ===============================================");
           $display("|   PIN %2d                                      |", p);
           $display(" ===============================================");

           // Rising edge only
           wr(R_IRQ_FALL, 32'h0);
           wr(R_IRQ_RISE, pbit(p));
           wr(R_IRQ_EN,   pbit(p));
           cycles(L_IN + 3);
           rd(R_IRQ_PEND, 32'h0);
           pin_edge_lat(p, 1'b1);
           if (lat != L_IN + 1)
             begin
                $display("ERROR: rising edge latched on edge %0d after the pin change, expected %0d %t ns", lat, L_IN + 1, $time);
                error = error + 1;
             end
           else
             $display("PASS:  rising edge latched on edge %0d", lat);
           rd(R_IRQ_PEND, pbit(p));
           chk32(irq32, pbit(p), "irq_o after a rising edge");
           chk(irq_any === 1'b1, "irq_any_o after a rising edge");
           pins_set(gpio_ext & ~pbit(p));          // falling: not a selected edge
           cycles(L_IN + 3);
           rd(R_IRQ_PEND, pbit(p));                // still latched
           pins_set(gpio_ext | pbit(p));           // second rising edge: stays set
           cycles(L_IN + 3);
           rd(R_IRQ_PEND, pbit(p));
           wr(R_IRQ_PEND, 32'h0);                  // writing 0 clears nothing
           rd(R_IRQ_PEND, pbit(p));
           wr(R_IRQ_PEND, ~pbit(p));               // other bits: nothing
           rd(R_IRQ_PEND, pbit(p));
           w1c_exact(pbit(p), pbit(p), 32'h0);
           chk(irq_any === 1'b0, "irq_any_o after the W1C");
           rd(R_IRQ_PEND, 32'h0);
           pins_set(gpio_ext & ~pbit(p));
           cycles(L_IN + 3);
           rd(R_IRQ_PEND, 32'h0);                  // falling with IRQ_FALL=0: nothing

           // Falling edge only
           wr(R_IRQ_FALL, pbit(p));
           wr(R_IRQ_RISE, 32'h0);
           pins_set(gpio_ext | pbit(p));
           cycles(L_IN + 3);
           rd(R_IRQ_PEND, 32'h0);                  // rising with IRQ_RISE=0: nothing
           pin_edge_lat(p, 1'b0);
           if (lat != L_IN + 1)
             begin
                $display("ERROR: falling edge latched on edge %0d after the pin change, expected %0d %t ns", lat, L_IN + 1, $time);
                error = error + 1;
             end
           rd(R_IRQ_PEND, pbit(p));
           pins_set(gpio_ext | pbit(p));
           cycles(L_IN + 3);
           rd(R_IRQ_PEND, pbit(p));                // stays latched after the pin returns
           w1c_exact(pbit(p), pbit(p), 32'h0);
           rd(R_IRQ_PEND, 32'h0);

           // Both edges
           wr(R_IRQ_RISE, pbit(p));
           pins_set(gpio_ext & ~pbit(p));
           cycles(L_IN + 3);
           rd(R_IRQ_PEND, pbit(p));
           wr(R_IRQ_PEND, pbit(p));
           rd(R_IRQ_PEND, 32'h0);
           pins_set(gpio_ext | pbit(p));
           cycles(L_IN + 3);
           rd(R_IRQ_PEND, pbit(p));
           wr(R_IRQ_PEND, pbit(p));
           rd(R_IRQ_PEND, 32'h0);

           // One-cycle pulse: stable for one pclk period at the sampling point
           @(posedge free_clk);
           #10;
           gpio_ext = gpio_ext & ~pbit(p);
           @(posedge free_clk);
           #10;
           gpio_ext = gpio_ext | pbit(p);
           cycles(L_IN + 3);
           rd(R_IRQ_PEND, pbit(p));
           wr(R_IRQ_PEND, pbit(p));
           rd(R_IRQ_PEND, 32'h0);

           // Latched bit survives clearing the mode bits
           pins_set(gpio_ext & ~pbit(p));
           cycles(L_IN + 3);
           wr(R_IRQ_RISE, 32'h0);
           wr(R_IRQ_FALL, 32'h0);
           rd(R_IRQ_PEND, pbit(p));
           chk32(irq32, pbit(p), "irq_o kept after the mode bits are cleared");
           wr(R_IRQ_PEND, pbit(p));
           rd(R_IRQ_PEND, 32'h0);
           wr(R_IRQ_EN, 32'h0);
        end

      $display(" ===============================================");
      $display("|   ALL PINS AT ONCE                            |");
      $display(" ===============================================");
      pins_set(32'h0);
      wr(R_IRQ_RISE, 32'hFFFFFFFF);
      wr(R_IRQ_EN,   32'hFFFFFFFF);
      cycles(L_IN + 3);
      pins_set(32'hFFFFFFFF);
      cycles(L_IN + 3);
      rd(R_IRQ_PEND, GPIO_MASK);
      w1c_exact(32'h0000FFFF, GPIO_MASK, GPIO_MASK & 32'hFFFF0000);
      rd(R_IRQ_PEND, GPIO_MASK & 32'hFFFF0000);
      w1c_exact(32'hFFFF0000, GPIO_MASK & 32'hFFFF0000, 32'h0);
      rd(R_IRQ_PEND, 32'h0);
      wr(R_IRQ_RISE, 32'h0);
      wr(R_IRQ_EN,   32'h0);

      cycles(20);
      stimulus_done = 1;
   end
