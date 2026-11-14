//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    input_latency
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : input_latency.v
// Module Description : gpio_i -> input register latency: exactly 3 pclk edges
//                      with SYNC_EN=1, 1 edge with SYNC_EN=0, on rising and
//                      falling pins, measured on a spread of pins.
//
// Doc "Inputs": "With SYNC_EN=1 a pin change appears in INPUT three pclk_aon_i
// edges after it settles at gpio_i (two synchroniser stages and the input
// register); with SYNC_EN=0, one edge." (edges of pclk_aon_i). Every pin is
// enabled (IN_EN) and past its flush first.
//
// Probe: a level interrupt. Doc "Interrupts": levels are built "from the
// input register" and are live ("IRQ_PEND[n] reads the OR of the latched
// edge bit and the live level condition"), and irq_o = IRQ_PEND & IRQ_EN
// (doc "Ports"), so irq_o follows the input register on the same edge.
// The pins change #10 after an edge; edge k is the k-th rising edge after.
//
// INPUT itself is bracketed by bus reads: a read whose ACCESS cycle ends on
// edge L returns the old value, a read whose SETUP cycle ends on edge L+1 or
// later returns the new value; the read in between is not checked.
// pclk_aon_i runs throughout (oscillator on); edges are counted on it.
//----------------------------------------------------------------------------

integer    ii;
integer    kk;
integer    p;
reg [31:0] val;
reg [31:0] old_v;

// Pin p goes to 'level'; irq_o[p] (level mode armed on p) must switch on
// edge L_IN exactly.
task measure;
   input integer pp;
   input         level;          // new pin value
   input         irq_after;      // irq_o[pp] expected from edge L_IN on
   begin
      @(posedge free_clk);
      #10;
      gpio_ext = level ? (gpio_ext | pbit(pp)) : (gpio_ext & ~pbit(pp));
      for (kk = 1; kk <= L_IN + 2; kk = kk + 1)
        begin
           @(posedge free_clk);
           #1;
           if (kk < L_IN)
             chk(((irq32 & pbit(pp)) != 0) === ~irq_after, "irq_o switched before the input latency");
           else
             chk(((irq32 & pbit(pp)) != 0) === irq_after,  "irq_o did not switch exactly at the input latency");
        end
   end
endtask

initial
   begin
      wait_reset_done(5);
      $display("SYNC_EN=%0d: expected latency %0d edge(s)", SYNC_EN, L_IN);

      $display(" ===============================================");
      $display("|   LATENCY ON irq_o (LEVEL MODE)               |");
      $display(" ===============================================");
      gpio_ext = 32'h0;
      inputs_on(32'hFFFFFFFF);
      wr(R_IRQ_HIGH, pbit(pick_pin(0)));
      for (ii = 0; ii < PICK_PIN_NR; ii = ii + 1)
        begin
           p = pick_pin(ii);
           $display("pin %0d", p);
           wr(R_IRQ_HIGH, pbit(p));
           wr(R_IRQ_EN,   pbit(p));
           cycles(L_IN + 2);
           chk((irq32 & pbit(p)) == 0, "irq_o low with the pin low");
           measure(p, 1'b1, 1'b1);             // rising pin, high level appears
           measure(p, 1'b0, 1'b0);             // falling pin, high level disappears
        end

      // Low-level mode: the falling pin raises the line with the same latency
      p = pick_pin(2);
      wr(R_IRQ_LOW,  pbit(p));
      wr(R_IRQ_HIGH, 32'h0);
      wr(R_IRQ_EN,   pbit(p));
      pins_set(gpio_ext | pbit(p));
      cycles(L_IN + 2);
      chk((irq32 & pbit(p)) == 0, "irq_o low with the pin high in low-level mode");
      measure(p, 1'b0, 1'b1);
      measure(p, 1'b1, 1'b0);

      $display(" ===============================================");
      $display("|   LATENCY BRACKETED BY INPUT READS            |");
      $display(" ===============================================");
      for (ii = 0; ii < 6; ii = ii + 1)
        begin
           old_v = gpio_ext & GPIO_MASK;
           val   = $urandom;
           if ((val & GPIO_MASK) == old_v) val = ~val;
           if (L_IN == 1)
             begin
                // read sampled on edge E0 (ends on E1 = latency edge), pins change after E0
                @(posedge free_clk);
                #1;
                apb_read(0, MACHINE, R_INPUT, old_v, SZ_W, 1'b1, OK);
                #9;
                gpio_ext = val;
             end
           else
             begin
                // pins change after E0, read sampled on E(L-1), ends on E(L)
                @(posedge free_clk);
                #10;
                gpio_ext = val;
                repeat (L_IN - 2) @(posedge free_clk);
                #1;
                apb_read(0, MACHINE, R_INPUT, old_v, SZ_W, 1'b1, OK);
             end
           apb_read(0, MACHINE, R_INPUT, 32'h0, SZ_W, 1'b0, OK);           // sampled on E(L): not checked
           apb_read(1, MACHINE, R_INPUT, val & GPIO_MASK, SZ_W, 1'b1, OK); // sampled on E(L+1)
        end

      $display(" ===============================================");
      $display("|   RANDOM PATTERNS                             |");
      $display(" ===============================================");
      for (ii = 0; ii < 16; ii = ii + 1)
        begin
           val = $urandom;
           pins_set(val);
           cycles(L_IN + 1);
           rd(R_INPUT, val & GPIO_MASK);
        end

      cycles(20);
      stimulus_done = 1;
   end
