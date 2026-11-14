//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    alt_input_path
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : alt_input_path.v
// Module Description : The GPIO input path on a handed-over pin, pad
//                      loop-back on: a level driven by the pin's function
//                      reaches INPUT with the normal latency (the wake pulse
//                      rises with the change and drops on edge L, when INPUT
//                      has caught up), rising / falling edges latch into
//                      IRQ_PEND on edge L+1 and raise irq_o / irq_any_o;
//                      with the function's oe=0 the pin reads the external
//                      level (neither the function's nor the software output
//                      leaks); handing a pin over and back with an unchanged
//                      pad level does not flush or disturb INPUT, raises no
//                      edge and no wake; IN_EN=0 still silences a handed pin.
//                      Spread of pins, functions in turn. Skips with ALT_NR=0.
//
// Doc "Alternate functions" (Inputs): "The GPIO input path is not affected by
// ALT_EN: with IN_EN set, INPUT, the interrupts and the wake request still
// follow a handed-over pin (a UART receive pin can wake the system on its
// start bit)."
// Doc "Inputs": "With SYNC_EN=1 a pin change appears in INPUT three pclk_aon_i
// edges after it settles at gpio_i ...; with SYNC_EN=0, one edge." "Pins are
// sampled whatever their OE, so a driven pin reads back its own output
// (through the pad)." "While IN_EN[n]=0 ... INPUT[n] reads 0, and the pin
// raises no edge, no level and no wake request."
// Doc "Wake": "While the clock runs, gpio_wake_o also pulses for a few cycles
// after every change of a wake-enabled pin." gpio_wake_o = ... (gpio_i[n] !=
// INPUT[n]): the pulse lasts until INPUT has caught up (as wake_running).
// Doc "Interrupts": a rising / falling edge with IRQ_RISE / IRQ_FALL sets
// IRQ_PEND[n]; irq_o[n] = IRQ_PEND[n] & IRQ_EN[n]. The latch edge L+1 is the
// reading measured and asserted by irq_edge.
// Alternate inputs change #10 after a rising edge (never on an edge), like
// pins_set.
//----------------------------------------------------------------------------

`define LONG_TIMEOUT

integer    ii;
integer    kk;
integer    p;
integer    fk;
integer    lat;
reg [31:0] ip_s0, ip_s1;
reg        ip_v;
reg        ip_no_wake;                   // 1: a rising gpio_wake_o is an error

always @(posedge gpio_wake)
  if ((ip_no_wake === 1'b1) && (presetn === 1'b1))
    begin
       $display("ERROR: gpio_wake_o raised with no pin change %t ns", $time);
       error = error+1;
    end

// Hand pin pp alone to function k (ALT_EN written last)
task ip_hand;
   input integer pp;
   input integer k;
   begin
      wr(R_ALT_EN, 32'h0);
      ip_s0 = ((k % 2) != 0)       ? pbit(pp) : 32'h0;
      ip_s1 = (((k / 2) % 2) != 0) ? pbit(pp) : 32'h0;
      wr(R_ALT_SEL0, ip_s0);
      wr(R_ALT_SEL1, ip_s1);
      wr(R_ALT_EN, pbit(pp));
      chk32((k == 0) ? alt_act32[0] : (k == 1) ? alt_act32[1] : (k == 2) ? alt_act32[2] : alt_act32[3],
            pbit(pp), "pin owned by its function");
   end
endtask

// Set function k's output for pin pp (oe given) #10 after a rising edge
task ip_alt_set;
   input integer k;
   input integer pp;
   input         o;
   input         oe;
   begin
      @(posedge free_clk);
      #10;
      alt_drive(k, o  ? (tb_alt_o[k]  | pbit(pp)) : (tb_alt_o[k]  & ~pbit(pp)),
                   oe ? (tb_alt_oe[k] | pbit(pp)) : (tb_alt_oe[k] & ~pbit(pp)));
   end
endtask

// Function k drives pin pp to 'level' (oe=1); check the wake pulse (high at
// once, low from edge L), the edge latch on edge L+1, then INPUT / IRQ_PEND
task ip_alt_edge;
   input integer k;
   input integer pp;
   input         level;
   begin
      lat = 0;
      @(posedge free_clk);
      #10;
      alt_drive(k, level ? (tb_alt_o[k] | pbit(pp)) : (tb_alt_o[k] & ~pbit(pp)), tb_alt_oe[k] | pbit(pp));
      #1;
      chk(((gpio_o32 & pbit(pp)) != 0) == level, "handed pin drives the function's level");
      chk(gpio_wake === 1'b1, "wake pulse starts with the function's pin change");
      for (kk = 1; kk <= L_IN + 3; kk = kk + 1)
        begin
           @(posedge free_clk);
           #1;
           if (kk < L_IN)
             chk(gpio_wake === 1'b1, "wake pulse held until INPUT catches up");
           else
             chk(gpio_wake === 1'b0, "wake pulse over once INPUT caught up (edge L)");
           if ((lat == 0) && ((irq32 & pbit(pp)) != 0))
             lat = kk;
        end
      if (lat != L_IN + 1)
        begin
           $display("ERROR: function-driven edge latched on edge %0d after the change, expected %0d %t ns", lat, L_IN + 1, $time);
           error = error + 1;
        end
      else
        $display("PASS:  function-driven edge latched on edge %0d", lat);
      chk(irq_any === 1'b1, "irq_any_o after a function-driven edge");
      rd(R_INPUT,    level ? pbit(pp) : 32'h0);
      rd(R_IRQ_PEND, pbit(pp));
      wr(R_IRQ_PEND, pbit(pp));
      rd(R_IRQ_PEND, 32'h0);
      chk32(irq32, 32'h0, "irq_o cleared");
   end
endtask

initial
   begin
      ip_no_wake = 1'b0;
      wait_reset_done(5);
      if (ALT_NR == 0)
        tb_skip_finish("|   ALT_NR=0: no alternate function to observe  |");

      gpio_ext    = 32'h0;
      tb_pad_loop = 1'b1;
      inputs_on(32'hFFFFFFFF);

      for (ii = 0; ii < PICK_PIN_NR; ii = ii + 1)
        begin
           p  = pick_pin(ii);
           fk = ii % ALT_NR;
           $display(" ===============================================");
           $display("|   PIN %2d, FUNCTION %0d                         |", p, fk);
           $display(" ===============================================");

           // Function drives the pin low, then the pin is handed over
           wr(R_OUTPUT, 32'h0);
           wr(R_OE,     32'h0);
           ip_alt_set(fk, p, 1'b0, 1'b1);
           ip_hand(p, fk);
           cycles(L_IN + 3);
           wr(R_IRQ_PEND, 32'hFFFFFFFF);
           rd(R_INPUT,    32'h0);
           rd(R_IRQ_PEND, 32'h0);

           // Driven level: INPUT, edges, interrupt, wake
           wr(R_WAKE_EN,  pbit(p));
           wr(R_IRQ_EN,   pbit(p));
           wr(R_IRQ_FALL, 32'h0);
           wr(R_IRQ_RISE, pbit(p));
           ip_alt_edge(fk, p, 1'b1);
           wr(R_IRQ_RISE, 32'h0);
           wr(R_IRQ_FALL, pbit(p));
           ip_alt_edge(fk, p, 1'b0);
           wr(R_IRQ_RISE, pbit(p));
           ip_alt_edge(fk, p, 1'b1);
           ip_alt_edge(fk, p, 1'b0);

           // Function oe=0: the pin reads the external level; the function's
           // o and the software OUTPUT (OE=1) are both the opposite level
           wr(R_IRQ_RISE, 32'h0);
           wr(R_IRQ_FALL, 32'h0);
           wr(R_WAKE_EN,  32'h0);
           wr(R_OE,       32'hFFFFFFFF);
           for (kk = 0; kk < 4; kk = kk + 1)
             begin
                ip_v = kk % 2;
                wr(R_OUTPUT, ip_v ? 32'h0 : pbit(p));
                ip_alt_set(fk, p, ~ip_v, 1'b0);
                #1;
                chk((gpio_oe32 & pbit(p)) == 0,               "function oe=0: gpio_oe_o low on the handed pin");
                chk(((gpio_o32 & pbit(p)) != 0) == ~ip_v,     "function oe=0: gpio_o still follows alt<k>_o_i");
                pins_set(ip_v ? (gpio_ext | pbit(p)) : (gpio_ext & ~pbit(p)));
                cycles(L_IN + 2);
                rd(R_INPUT, ip_v ? pbit(p) : 32'h0);
             end
           wr(R_IRQ_PEND, 32'hFFFFFFFF);

           // Hand-over and release with an unchanged pad level: no flush,
           // no edge, no wake. Pad high from outside, function oe=0,
           // software OE=0.
           wr(R_OE, 32'h0);
           pins_set(gpio_ext | pbit(p));
           cycles(L_IN + 3);
           wr(R_IRQ_RISE, pbit(p));
           wr(R_IRQ_FALL, pbit(p));
           wr(R_WAKE_EN,  pbit(p));
           wr(R_IRQ_PEND, 32'hFFFFFFFF);
           rd(R_INPUT,    pbit(p));
           ip_no_wake = 1'b1;
           for (kk = 0; kk < 4; kk = kk + 1)
             begin
                wr(R_ALT_EN, (kk % 2) ? pbit(p) : 32'h0);
                rd(R_INPUT, pbit(p));                       // read right away: no flush to 0
                rd(R_INPUT, pbit(p));
                rd(R_IN_EN, GPIO_MASK);
             end
           cycles(L_IN + 3);
           ip_no_wake = 1'b0;
           rd(R_IRQ_PEND, 32'h0);
           chk32(irq32, 32'h0, "no interrupt from ALT_EN writes");

           // IN_EN=0 silences a handed pin
           wr(R_IRQ_RISE, 32'h0);
           wr(R_IRQ_FALL, 32'h0);
           pins_set(gpio_ext & ~pbit(p));
           ip_alt_set(fk, p, 1'b0, 1'b1);
           wr(R_ALT_EN, pbit(p));
           cycles(L_IN + 3);
           wr(R_IRQ_PEND, 32'hFFFFFFFF);
           wr(R_IRQ_RISE, pbit(p));
           wr(R_IRQ_FALL, pbit(p));
           wr(R_IN_EN, GPIO_MASK & ~pbit(p));
           cycles(2);
           ip_no_wake = 1'b1;
           for (kk = 0; kk < 4; kk = kk + 1)
             begin
                ip_alt_set(fk, p, (kk % 2) == 0, 1'b1);
                cycles(L_IN + 2);
                rd(R_INPUT,    32'h0);
                rd(R_IRQ_PEND, 32'h0);
             end
           ip_no_wake = 1'b0;
           ip_alt_set(fk, p, 1'b0, 1'b1);
           cycles(2);
           inputs_on(32'hFFFFFFFF);
           wr(R_IRQ_RISE, 32'h0);
           wr(R_IRQ_FALL, 32'h0);
           wr(R_WAKE_EN,  32'h0);
           wr(R_IRQ_EN,   32'h0);
           wr(R_IRQ_PEND, 32'hFFFFFFFF);
           wr(R_ALT_EN,   32'h0);
           ip_alt_set(fk, p, 1'b0, 1'b0);
        end

      cycles(20);
      stimulus_done = 1;
   end
