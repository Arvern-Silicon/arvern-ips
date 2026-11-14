//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    alt_registers
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : alt_registers.v
// Module Description : ALT_EN / ALT_SEL0 / ALT_SEL1 reset values, word, byte
//                      and half-word writes, whole-word reads at every size,
//                      bits above GPIO_NR-1; absent registers (per ALT_NR)
//                      read 0 and ignore writes; ALT_SEL writes with ALT_EN=0
//                      and absent-register writes with ALT_EN=1 never move
//                      gpio_o / gpio_oe_o / alt<k>_act_o; refused writes with
//                      MDELEG Machine-only; a mid-test reset returns every pin to
//                      software control. Runs at every ALT_NR, 0 included.
//
// Doc "Register map": ALT_EN (0x40) RW reset 0 "(ALT_NR >= 1)", ALT_SEL0
// (0x44) "(ALT_NR >= 2)", ALT_SEL1 (0x48) "(ALT_NR >= 3)"; "A register whose
// ALT_NR condition is not met is absent: it reads 0 and ignores writes, like
// an unlisted offset." "Byte and half-word writes update only the addressed
// byte lanes; reads always return the whole word."
// Doc "Parameters": "Register bits above GPIO_NR-1 read 0 and ignore writes."
// ALT_NR "0: no ALT_* register."
// Doc "Alternate functions" (Selection): "While ALT_EN[n]=0 the pin is under
// software control (OUTPUT, OE)." "a function number of ALT_NR or more ...
// selects nothing and the pin is not driven"; "the absent bits read 0".
// (Switching): "At reset every pin is under software control."
// Doc "Access protection": "a denied write changes nothing and a denied read
// returns 0."
// The expected pins are computed after every write from a shadow of the
// registers and the alternate-function inputs (all four driven non-zero).
//----------------------------------------------------------------------------

`define LONG_TIMEOUT

integer    ii;
integer    jj;
integer    rr;
reg [31:0] ar_sh [0:2];         // shadow: ALT_EN, ALT_SEL0, ALT_SEL1 (as the DUT holds them)
reg [31:0] ar_out;
reg [31:0] ar_oe;
reg        ar_watch;            // 1: any change of gpio_o / gpio_oe_o / act is an error
reg [31:0] ar_v;

wire [31:0] ar_act0 = alt_act32[0];
wire [31:0] ar_act1 = alt_act32[1];
wire [31:0] ar_act2 = alt_act32[2];
wire [31:0] ar_act3 = alt_act32[3];

// Expected ownership of function k (doc "Selection")
function [31:0] ar_act;
   input integer k;
   reg   [31:0] s0;
   reg   [31:0] s1;
   begin
      s0 = ((k % 2) != 0)       ? ar_sh[1] : ~ar_sh[1];
      s1 = (((k / 2) % 2) != 0) ? ar_sh[2] : ~ar_sh[2];
      if (k >= ALT_NR) ar_act = 32'h0;
      else             ar_act = ar_sh[0] & s0 & s1 & GPIO_MASK;
   end
endfunction

function [31:0] ar_exp_o;
   input integer dummy;
   begin
      ar_exp_o = ((ar_out & ~ar_sh[0]) | (tb_alt_o[0] & ar_act(0)) | (tb_alt_o[1] & ar_act(1)) |
                  (tb_alt_o[2] & ar_act(2)) | (tb_alt_o[3] & ar_act(3))) & GPIO_MASK;
   end
endfunction

function [31:0] ar_exp_oe;
   input integer dummy;
   begin
      ar_exp_oe = ((ar_oe & ~ar_sh[0]) | (tb_alt_oe[0] & ar_act(0)) | (tb_alt_oe[1] & ar_act(1)) |
                   (tb_alt_oe[2] & ar_act(2)) | (tb_alt_oe[3] & ar_act(3))) & GPIO_MASK;
   end
endfunction

task ar_chk_pins;
   input [60*8-1:0] msg;
   begin
      if ((gpio_o32 !== ar_exp_o(0)) || (gpio_oe32 !== ar_exp_oe(0)) ||
          (ar_act0 !== ar_act(0)) || (ar_act1 !== ar_act(1)) ||
          (ar_act2 !== ar_act(2)) || (ar_act3 !== ar_act(3)))
        begin
           $display("ERROR: %0s -- gpio_o 0x%h/0x%h gpio_oe_o 0x%h/0x%h act3..0 0x%h_%h_%h_%h/0x%h_%h_%h_%h (got/expected) %t ns",
                    msg, gpio_o32, ar_exp_o(0), gpio_oe32, ar_exp_oe(0),
                    ar_act3, ar_act2, ar_act1, ar_act0, ar_act(3), ar_act(2), ar_act(1), ar_act(0), $time);
           error = error+1;
        end
      else
        $display("PASS:  %0s -- gpio_o 0x%h gpio_oe_o 0x%h %t ns", msg, gpio_o32, gpio_oe32, $time);
   end
endtask

// Pins and ownership must not move while ar_watch is set
always @(gpio_o32 or gpio_oe32 or ar_act0 or ar_act1 or ar_act2 or ar_act3)
  if ((ar_watch === 1'b1) && (presetn === 1'b1))
    begin
       $display("ERROR: gpio_o / gpio_oe_o / alt_act changed where no change is allowed -- gpio_o=0x%h gpio_oe_o=0x%h act3..0=0x%h_%h_%h_%h %t ns",
                gpio_o32, gpio_oe32, ar_act3, ar_act2, ar_act1, ar_act0, $time);
       error = error+1;
    end

// Write to ALT register idx (0 EN, 1 SEL0, 2 SEL1) at address a, any size;
// shadow update, whole-word read back at every size, pins checked
task ar_write;
   input integer idx;
   input  [31:0] a;
   input  [31:0] data;
   input   [1:0] size;
   reg    [31:0] lm;
   reg    [31:0] base;
   begin
      base = R_ALT_EN + 4*idx;
      lm   = lane_mask(a, size);
      if (alt_reg_present(base - GPIO_BASE))
        ar_sh[idx] = ((ar_sh[idx] & ~lm) | (lane_place(a, size, data) & lm)) & GPIO_MASK;
      apb_write(1, MACHINE, a, data, size, OK);
      apb_read(1, MACHINE, base,     ar_sh[idx], SZ_W, 1'b1, OK);
      apb_read(1, MACHINE, base + 0, ar_sh[idx], SZ_B, 1'b1, OK);
      apb_read(1, MACHINE, base + 1, ar_sh[idx], SZ_B, 1'b1, OK);
      apb_read(1, MACHINE, base + 2, ar_sh[idx], SZ_B, 1'b1, OK);
      apb_read(1, MACHINE, base + 3, ar_sh[idx], SZ_B, 1'b1, OK);
      apb_read(1, MACHINE, base + 0, ar_sh[idx], SZ_H, 1'b1, OK);
      apb_read(1, MACHINE, base + 2, ar_sh[idx], SZ_H, 1'b1, OK);
      ar_chk_pins("pins after an ALT register write");
   end
endtask

// Word, byte and half-word walk over one ALT register
task ar_walk;
   input integer idx;
   reg    [31:0] base;
   begin
      base = R_ALT_EN + 4*idx;
      ar_write(idx, base, 32'hFFFFFFFF, SZ_W);
      ar_write(idx, base, 32'h00000000, SZ_W);
      ar_write(idx, base, 32'hA5A5A5A5, SZ_W);
      ar_write(idx, base, 32'h5A5A5A5A, SZ_W);
      ar_write(idx, base, 32'h00000000, SZ_W);
      for (jj = 0; jj < 4; jj = jj + 1)
        ar_write(idx, base + jj, $urandom | 32'h81, SZ_B);
      for (jj = 0; jj < 4; jj = jj + 1)
        ar_write(idx, base + jj, 32'h00, SZ_B);
      ar_write(idx, base,     32'hFFFF,  SZ_H);
      ar_write(idx, base + 2, $urandom,  SZ_H);
      ar_write(idx, base,     32'h0000,  SZ_H);
      ar_write(idx, base + 2, 32'hFFFF,  SZ_H);
      ar_write(idx, base, 32'hFFFFFFFF, SZ_W);
      for (jj = 0; jj < 4; jj = jj + 1)
        ar_write(idx, base + jj, 32'h00, SZ_B);
      ar_write(idx, base, $urandom, SZ_W);
   end
endtask

initial
   begin
      ar_watch = 1'b0;
      ar_sh[0] = 32'h0; ar_sh[1] = 32'h0; ar_sh[2] = 32'h0;
      ar_out   = 32'h0;
      ar_oe    = 32'h0;
      wait_reset_done(5);

      $display(" ===============================================");
      $display("|   RESET VALUES, SOFTWARE CONTROL AT RESET     |");
      $display(" ===============================================");
      rd(R_ALT_EN,   32'h0);
      rd(R_ALT_SEL0, 32'h0);
      rd(R_ALT_SEL1, 32'h0);
      ar_chk_pins("reset: pins under software control, no function active");
      // Every function drives every pin: at reset none of it reaches the pins
      @(posedge free_clk);
      #10;
      for (ii = 0; ii < 4; ii = ii + 1)
        alt_drive(ii, 32'hFFFFFFFF, 32'hFFFFFFFF);
      #1;
      chk32(gpio_o32,  32'h0, "reset: gpio_o = OUTPUT with every alt<k>_o_i high");
      chk32(gpio_oe32, 32'h0, "reset: gpio_oe_o = OE with every alt<k>_oe_i high");
      chk32(ar_act0 | ar_act1 | ar_act2 | ar_act3, 32'h0, "reset: no alt<k>_act_o bit");

      // Distinct software and function values
      ar_out = 32'h3C5A96F0 & GPIO_MASK;
      ar_oe  = 32'hA55AC33C & GPIO_MASK;
      wr(R_OUTPUT, ar_out);
      wr(R_OE,     ar_oe);
      @(posedge free_clk);
      #10;
      alt_drive(0, 32'h0F0F0F0F, 32'hFFFF0000);
      alt_drive(1, 32'h33333333, 32'h00FFFF00);
      alt_drive(2, 32'h55555555, 32'hF0F0F0F0);
      alt_drive(3, 32'hFFFFFFFF, 32'hFFFFFFFF);
      #1;
      ar_chk_pins("software values on every pin");

      $display(" ===============================================");
      $display("|   ALT_SEL0 / ALT_SEL1 WITH ALT_EN=0           |");
      $display(" ===============================================");
      ar_watch = 1'b1;
      ar_walk(1);
      ar_walk(2);
      if (ALT_NR == 0)
        begin
           $display(" ===============================================");
           $display("|   ALT_EN ABSENT (ALT_NR=0)                    |");
           $display(" ===============================================");
           ar_walk(0);
        end
      ar_watch = 1'b0;

      if (ALT_NR >= 1)
        begin
           $display(" ===============================================");
           $display("|   ALT_EN WALK                                 |");
           $display(" ===============================================");
           // SEL registers hold a mix of function numbers here
           ar_write(1, R_ALT_SEL0, 32'hCCCCCCCC, SZ_W);
           ar_write(2, R_ALT_SEL1, 32'hF0F0F0F0, SZ_W);
           ar_walk(0);

           $display(" ===============================================");
           $display("|   ABSENT ALT_SEL WITH ALT_EN=1                |");
           $display(" ===============================================");
           ar_write(0, R_ALT_EN, 32'hFFFFFFFF, SZ_W);
           ar_watch = 1'b1;
           if (ALT_NR < 2) ar_walk(1);
           if (ALT_NR < 3) ar_walk(2);
           // Unmapped word above the ALT registers
           apb_write(1, MACHINE, R_ALT_SEL1 + 4, 32'hFFFFFFFF, SZ_W, OK);
           apb_read(1, MACHINE, R_ALT_SEL1 + 4, 32'h0, SZ_W, 1'b1, OK);
           ar_watch = 1'b0;

           $display(" ===============================================");
           $display("|   PRESENT ALT_SEL WITH ALT_EN=1               |");
           $display(" ===============================================");
           if (ALT_NR >= 2) ar_walk(1);
           if (ALT_NR >= 3) ar_walk(2);
        end

        begin
           $display(" ===============================================");
           $display("|   REFUSED ACCESSES (MDELEG M-ONLY, RESP=1)    |");
           $display(" ===============================================");
           wr(R_MDELEG, 32'h0000010F);
           ar_watch = 1'b1;
           for (rr = 0; rr < 3; rr = rr + 1)
             begin
                apb_write(1, USER,       R_ALT_EN + 4*rr, ~ar_sh[rr], SZ_W, ERROR);
                apb_write(1, SUPERVISOR, R_ALT_EN + 4*rr, ~ar_sh[rr], SZ_W, ERROR);
                apb_write(1, USER_S,     R_ALT_EN + 4*rr + 2, 32'hFFFF, SZ_H, ERROR);
                apb_read(1, USER,       R_ALT_EN + 4*rr, 32'h0, SZ_W, 1'b1, ERROR);
                apb_read(1, SUPERVISOR, R_ALT_EN + 4*rr, 32'h0, SZ_W, 1'b1, ERROR);
                rd(R_ALT_EN + 4*rr, ar_sh[rr]);
             end
           ar_watch = 1'b0;
           ar_chk_pins("pins after denied ALT register writes");
        end

      $display(" ===============================================");
      $display("|   RESET WITH PINS HANDED OVER                 |");
      $display(" ===============================================");
      if (ALT_NR >= 1)
        begin
           ar_write(0, R_ALT_EN,   32'hFFFFFFFF, SZ_W);
           ar_write(1, R_ALT_SEL0, 32'h5A5A5A5A, SZ_W);
           ar_write(2, R_ALT_SEL1, 32'h3C3C3C3C, SZ_W);
        end
      @(posedge free_clk);
      #10;
      for (ii = 0; ii < 4; ii = ii + 1)
        alt_drive(ii, 32'hFFFFFFFF, 32'hFFFFFFFF);
      #1;
      ar_chk_pins("before reset");
      tb_reset_pulse(4);
      cycles(2);
      ar_sh[0] = 32'h0; ar_sh[1] = 32'h0; ar_sh[2] = 32'h0;
      ar_out   = 32'h0;
      ar_oe    = 32'h0;
      chk32(gpio_o32,  32'h0, "after reset: gpio_o = OUTPUT (0) with every alt<k>_o_i high");
      chk32(gpio_oe32, 32'h0, "after reset: gpio_oe_o = OE (0) with every alt<k>_oe_i high");
      chk32(ar_act0 | ar_act1 | ar_act2 | ar_act3, 32'h0, "after reset: no alt<k>_act_o bit");
      rd(R_ALT_EN,   32'h0);
      rd(R_ALT_SEL0, 32'h0);
      rd(R_ALT_SEL1, 32'h0);
      ar_chk_pins("after reset");

      @(posedge free_clk);
      #10;
      for (ii = 0; ii < 4; ii = ii + 1)
        alt_drive(ii, 32'h0, 32'h0);
      cycles(20);
      stimulus_done = 1;
   end
