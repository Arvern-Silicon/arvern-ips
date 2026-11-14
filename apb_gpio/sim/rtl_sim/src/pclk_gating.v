//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    pclk_gating
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : pclk_gating.v
// Module Description : pclk_en_o: high in the SETUP and ACCESS cycles of a
//                      transfer (also one started late in a cycle), low
//                      (and pclk
//                      stopped) whenever the bus is idle -- no register
//                      state holds it: mode bits, IN_EN, WAKE_EN, IRQ_EN,
//                      OUTPUT, OE, a latched or level IRQ_PEND bit; irq_o
//                      holds with the bus clock stopped; INPUT is current on
//                      the first read after an idle period; low during
//                      reset (the reset generator requests the clock).
//
// Doc "Clocks": "pclk_i clocks the bus interface and the registers.
// pclk_en_o requests it while the completer is selected; during reset the
// reset generator requests it." "Because the input path keeps running while the bus clock is
// gated, INPUT is always current for enabled pins".
// The drop of pclk_en_o after an access is not specified to the cycle: it is
// required within 3 cycles.
//----------------------------------------------------------------------------

integer    ii;
integer    rr;
integer    n0;
reg [31:0] addr;
reg [31:0] v0;
reg [31:0] v1;
reg [31:0] rdat;

// pclk_en_o must fall within 3 cycles and then stay low for 'n' cycles
task expect_idle_low;
   input integer n;
   integer k;
   begin
      k = 0;
      @(negedge free_clk);
      while ((pclk_en !== 1'b0) && (k < 3))
        begin
           k = k + 1;
           @(negedge free_clk);
        end
      chk(pclk_en === 1'b0, "pclk_en_o low within 3 cycles of going idle");
      n0 = pclk_cnt;
      repeat (n)
        begin
           @(negedge free_clk);
           chk(pclk_en === 1'b0, "pclk_en_o stays low while the bus is idle");
        end
      chk(pclk_cnt == n0, "no pclk edge while the bus is idle");
      #1;
   end
endtask

// A single transfer driven by hand, SETUP starting 'late' ns after a rising
// edge: pclk_en_o checked in both cycles
task access_phases;
   input        write;
   input [31:0] a;
   input [31:0] d;
   input integer late;
   begin
      @(posedge free_clk);
      #(1 + late);
      psel    = 1'b1;
      penable = 1'b0;
      paddr   = a[ADDRW-1:0];
      pwrite  = write;
      pwdata  = d;
      pstrb   = write ? 4'hF : 4'h0;
      pprot   = {tb_pprot_other, MACHINE[1]};
      psmode  = MACHINE[0];
      if (free_clk === 1'b1) @(negedge free_clk);
      else                   #1;
      chk(pclk_en === 1'b1, "pclk_en_o high in SETUP");
      @(posedge free_clk);
      #1;
      penable = 1'b1;
      @(negedge free_clk);
      chk(pclk_en === 1'b1, "pclk_en_o high in ACCESS");
      rdat = prdata;
      @(posedge free_clk);
      #1;
      apb_idle;
   end
endtask

initial
   begin
      wait_reset_done(5);

      $display(" ===============================================");
      $display("|   IDLE AFTER RESET                            |");
      $display(" ===============================================");
      expect_idle_low(10);

      $display(" ===============================================");
      $display("|   SETUP AND ACCESS CYCLES                     |");
      $display(" ===============================================");
      access_phases(1'b1, R_OUTPUT, 32'h12345678, 0);
      chk32(gpio_o32, 32'h12345678 & GPIO_MASK, "write completed through the gated clock");
      expect_idle_low(10);
      access_phases(1'b0, R_OUTPUT, 32'h0, 0);
      chk32(rdat, 32'h12345678 & GPIO_MASK, "read completed through the gated clock");
      expect_idle_low(10);
      // SETUP driven in the low phase, just before the edge that ends it
      access_phases(1'b1, R_OUT_TGL, 32'h000000FF, 40);
      chk32(gpio_o32, (32'h12345678 ^ 32'hFF) & GPIO_MASK, "late-started write completed through the gated clock");
      expect_idle_low(10);

      $display(" ===============================================");
      $display("|   NO REGISTER STATE HOLDS THE BUS CLOCK       |");
      $display(" ===============================================");
      // Mode bits, IN_EN, WAKE_EN, IRQ_EN, OUTPUT, OE: none requests pclk_i
      for (rr = 0; rr < 9; rr = rr + 1)
        begin
           case (rr)
             0: addr = R_IRQ_RISE;
             1: addr = R_IRQ_FALL;
             2: addr = R_IRQ_HIGH;
             3: addr = R_IRQ_LOW;
             4: addr = R_IN_EN;
             5: addr = R_WAKE_EN;
             6: addr = R_IRQ_EN;
             7: addr = R_OUTPUT;
             default: addr = R_OE;
           endcase
           wr(addr, 32'hFFFFFFFF);
           expect_idle_low(10);
        end
      // a latched pending bit and a live level, inputs running
      pins_set(32'hFFFFFFFF);
      cycles(L_IN + 3);
      wr(R_IRQ_LOW, 32'h0);
      rd(R_IRQ_PEND, GPIO_MASK);
      expect_idle_low(10);
      chk32(irq32, GPIO_MASK, "irq_o held while the bus clock is stopped");
      wr(R_IRQ_PEND, 32'hFFFFFFFF);
      rd(R_IRQ_PEND, GPIO_MASK);              // IRQ_HIGH level remains
      for (rr = 0; rr < 9; rr = rr + 1)
        begin
           case (rr)
             0: addr = R_IRQ_RISE;
             1: addr = R_IRQ_FALL;
             2: addr = R_IRQ_HIGH;
             3: addr = R_IRQ_LOW;
             4: addr = R_WAKE_EN;
             5: addr = R_IRQ_EN;
             6: addr = R_OUTPUT;
             7: addr = R_OE;
             default: addr = R_IRQ_PEND;
           endcase
           wr(addr, (rr == 8) ? 32'hFFFFFFFF : 32'h0);
        end
      expect_idle_low(10);

      $display(" ===============================================");
      $display("|   INPUT IS CURRENT AFTER A GATED PERIOD       |");
      $display(" ===============================================");
      // IN_EN still all-ones: the input stage runs on pclk_aon_i
      for (ii = 0; ii < 4; ii = ii + 1)
        begin
           v0 = $urandom & GPIO_MASK;
           v1 = ($urandom & GPIO_MASK) ^ v0;
           if (v1 == v0) v1 = ~v0 & GPIO_MASK;
           pins_set(v0);
           expect_idle_low(L_IN + 3);
           rd(R_INPUT, v0);
           expect_idle_low(3);
           n0 = pclk_cnt;
           pins_set(v1);
           expect_idle_low(L_IN + 3);
           chk(pclk_cnt == n0, "bus clock stopped while the pins changed");
           rd(R_INPUT, v1);                    // first read after the idle period: current
        end
      wr(R_IN_EN, 32'h0);

      $display(" ===============================================");
      $display("|   RESET                                       |");
      $display(" ===============================================");
      wr(R_OUTPUT, 32'hFFFFFFFF);
      @(posedge free_clk);
      #10;
      presetn = 1'b0;
      repeat (4)
        begin
           @(negedge free_clk);
           chk(pclk_en === 1'b0, "pclk_en_o low during reset");
        end
      @(posedge free_clk);
      #10;
      presetn = 1'b1;
      apb_idle;
      expect_idle_low(10);
      chk32(gpio_o32, 32'h0, "OUTPUT reset through the gated clock");
      rd(R_OUTPUT, 32'h0);

      $display(" ===============================================");
      $display("|   SCAN MODE CHANGES NOTHING FUNCTIONAL        |");
      $display(" ===============================================");
      // scan_mode_i only forces the input-path clock gate open: with every
      // input disabled, INPUT and the outputs stay as they are
      wr(R_IN_EN, 32'h0);
      cycles(L_IN + 3);
      v0 = gpio_o32;
      v1 = gpio_oe32;
      @(posedge free_clk); #10;
      tb_scan_mode = 1'b1;
      pins_set(32'hFFFFFFFF);
      cycles(L_IN + 3);
      rd(R_INPUT, 32'h0);
      chk32(gpio_o32,  v0, "gpio_o unchanged in scan mode");
      chk32(gpio_oe32, v1, "gpio_oe_o unchanged in scan mode");
      chk(gpio_wake === 1'b0, "no wake request from a disabled pin in scan mode");
      @(posedge free_clk); #10;
      tb_scan_mode = 1'b0;
      pins_set(32'h0);
      cycles(2);

      cycles(20);
      stimulus_done = 1;
   end
