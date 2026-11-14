//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    output_oe_rdwr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : output_oe_rdwr.v
// Module Description : OUTPUT and OE read/write and their reflection on
//                      gpio_o / gpio_oe_o.
//
// Doc "Register map": OUTPUT (0x10) RW "Output values, driven on gpio_o";
// OE (0x08) RW "Output enables, driven on gpio_oe_o"; INPUT is RO.
// Doc "Ports": gpio_o = OUTPUT register, gpio_oe_o = OE register.
// Doc "Interrupts" (handler sequence): "The write takes effect at the end of
// its ACCESS cycle" -- the pins are checked unchanged during the ACCESS cycle
// and changed right after the edge that ends it.
// Doc "Parameters": bits above GPIO_NR-1 read 0 (expectations are masked).
// Doc "Inputs": a pin is sampled only while its IN_EN bit is 1.
//----------------------------------------------------------------------------

integer    ii;
reg [31:0] val;
reg [31:0] prev_out;
reg [31:0] prev_oe;

// Write OUTPUT or OE, checking the pins switch exactly at the end of the
// ACCESS cycle, then read back.
task wr_pins_reg;
   input [31:0] addr;
   input [31:0] data;
   reg   [31:0] v_before;
   begin
      v_before = (addr == R_OUTPUT) ? gpio_o32 : gpio_oe32;
      apb_write(0, MACHINE, addr, data, SZ_W, OK);     // returns in the ACCESS cycle
      @(negedge free_clk);
      chk32((addr == R_OUTPUT) ? gpio_o32 : gpio_oe32, v_before, "pins unchanged during the write ACCESS cycle");
      @(posedge free_clk);
      #1;
      chk32((addr == R_OUTPUT) ? gpio_o32 : gpio_oe32, data & GPIO_MASK, "pins updated at the end of the ACCESS cycle");
      rd(addr, data & GPIO_MASK);
   end
endtask

initial
   begin
      wait_reset_done(5);
      inputs_on(32'hFFFFFFFF);  // INPUT is read below (doc "Inputs": sampled only while IN_EN=1)

      $display(" ===============================================");
      $display("|   OUTPUT / OE PATTERNS                        |");
      $display(" ===============================================");
      wr_pins_reg(R_OUTPUT, 32'hFFFFFFFF);
      chk32(gpio_oe32, 32'h0, "OE untouched by an OUTPUT write");
      wr_pins_reg(R_OE,     32'hFFFFFFFF);
      chk32(gpio_o32, GPIO_MASK, "OUTPUT untouched by an OE write");
      wr_pins_reg(R_OUTPUT, 32'h00000000);
      chk32(gpio_oe32, GPIO_MASK, "OE untouched by an OUTPUT write");
      wr_pins_reg(R_OE,     32'h00000000);
      wr_pins_reg(R_OUTPUT, 32'hA5A5A5A5);
      wr_pins_reg(R_OE,     32'h5A5A5A5A);
      wr_pins_reg(R_OUTPUT, 32'h5A5A5A5A);
      wr_pins_reg(R_OE,     32'hA5A5A5A5);

      $display(" ===============================================");
      $display("|   WALKING ONE / WALKING ZERO                  |");
      $display(" ===============================================");
      for (ii = 0; ii < 32; ii = ii + 1)
        begin
           wr_pins_reg(R_OUTPUT,  32'h1 << ii);
           wr_pins_reg(R_OE,    ~(32'h1 << ii));
        end
      for (ii = 0; ii < 32; ii = ii + 1)
        begin
           wr_pins_reg(R_OUTPUT, ~(32'h1 << ii));
           wr_pins_reg(R_OE,      32'h1 << ii);
        end

      $display(" ===============================================");
      $display("|   RANDOM VALUES, INDEPENDENCE                 |");
      $display(" ===============================================");
      for (ii = 0; ii < 16; ii = ii + 1)
        begin
           val     = $urandom;
           prev_oe = gpio_oe32;
           wr_pins_reg(R_OUTPUT, val);
           chk32(gpio_oe32, prev_oe, "OE untouched by an OUTPUT write");
           val      = $urandom;
           prev_out = gpio_o32;
           wr_pins_reg(R_OE, val);
           chk32(gpio_o32, prev_out, "OUTPUT untouched by an OE write");
        end

      $display(" ===============================================");
      $display("|   INPUT IS READ-ONLY                          |");
      $display(" ===============================================");
      val = $urandom;
      pins_set(val);
      cycles(L_IN + 2);
      rd(R_INPUT, val & GPIO_MASK);
      prev_out = gpio_o32;
      prev_oe  = gpio_oe32;
      wr(R_INPUT, ~val);
      rd(R_INPUT, val & GPIO_MASK);
      chk32(gpio_o32,  prev_out, "INPUT write leaves gpio_o");
      chk32(gpio_oe32, prev_oe,  "INPUT write leaves gpio_oe_o");

      cycles(20);
      stimulus_done = 1;
   end
