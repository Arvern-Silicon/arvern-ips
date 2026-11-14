//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    irq_bus_gated
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : irq_bus_gated.v
// Module Description : Edges and levels are recorded while the bus clock is
//                      gated: with the bus idle (pclk stopped, checked with
//                      the pclk edge counter) a rising / falling edge raises
//                      irq_o on edge L+1 of pclk_aon and a level on edge L,
//                      with no pclk edge at all; the first INPUT read after
//                      the idle period returns the current pins.
//
// Doc "Interrupts": "edges and levels of a pin are recorded while its bus
// clock is gated, since the pending latch also runs on pclk_aon_i."
// Doc "Clocks": "pclk_aon_i clocks the input stage, the edge detector, the
// pending latch and irq_o." "pclk_en_o requests it [pclk_i] while an APB
// access is in progress". "INPUT is always current for enabled pins and
// edges are not missed during bus idle periods."
//----------------------------------------------------------------------------

integer    ii;
integer    kk;
integer    p;
integer    lat;
integer    n0;

// Move pin pp with the bus idle; return in lat the pclk_aon edge on which
// irq_o[pp] rose; check no pclk edge happened.
task idle_pin_move;
   input integer pp;
   input         level;
   begin
      cycles(4);
      n0  = pclk_cnt;
      lat = 0;
      @(posedge free_clk);
      #10;
      gpio_ext = level ? (gpio_ext | pbit(pp)) : (gpio_ext & ~pbit(pp));
      for (kk = 1; kk <= L_IN + 4; kk = kk + 1)
        begin
           @(posedge free_clk);
           #1;
           if ((lat == 0) && ((irq32 & pbit(pp)) != 0)) lat = kk;
        end
      chk(pclk_cnt == n0, "bus clock stopped while the pin event was recorded");
      chk(pclk_en === 1'b0, "pclk_en_o low with the bus idle");
   end
endtask

initial
   begin
      wait_reset_done(5);
      gpio_ext      = 32'h0;
      tb_pclk_force = 1'b0;
      inputs_on(32'hFFFFFFFF);

      for (ii = 0; ii < PICK_PIN_NR; ii = ii + 1)
        begin
           p = pick_pin(ii);
           $display(" ===============================================");
           $display("|   PIN %2d                                      |", p);
           $display(" ===============================================");
           // Rising edge
           wr(R_IRQ_RISE, pbit(p));
           wr(R_IRQ_FALL, 32'h0);
           wr(R_IRQ_EN,   pbit(p));
           idle_pin_move(p, 1'b1);
           chk(lat == L_IN + 1, "rising edge latched on pclk_aon edge L+1 with the bus clock stopped");
           rd(R_INPUT, gpio_ext & GPIO_MASK);  // first read after the idle period: current
           rd(R_IRQ_PEND, pbit(p));
           wr(R_IRQ_PEND, pbit(p));
           // Falling edge
           wr(R_IRQ_FALL, pbit(p));
           wr(R_IRQ_RISE, 32'h0);
           idle_pin_move(p, 1'b0);
           chk(lat == L_IN + 1, "falling edge latched on pclk_aon edge L+1 with the bus clock stopped");
           rd(R_INPUT, gpio_ext & GPIO_MASK);
           rd(R_IRQ_PEND, pbit(p));
           wr(R_IRQ_PEND, pbit(p));
           wr(R_IRQ_FALL, 32'h0);
           // High level
           wr(R_IRQ_HIGH, pbit(p));
           idle_pin_move(p, 1'b1);
           chk(lat == L_IN, "high level on irq_o on pclk_aon edge L with the bus clock stopped");
           idle_pin_move(p, 1'b0);
           chk((irq32 & pbit(p)) == 0, "high level gone with the bus clock stopped");
           wr(R_IRQ_HIGH, 32'h0);
           wr(R_IRQ_EN,   32'h0);
           rd(R_IRQ_PEND, 32'h0);
        end

      cycles(20);
      stimulus_done = 1;
   end
