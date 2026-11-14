//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    alt_routing
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : alt_routing.v
// Module Description : Pin routing of the alternate functions: every pin
//                      handed to each present function in turn, then mixed
//                      assignments (different functions on different pins
//                      at once, part of the pins left to software); gpio_o /
//                      gpio_oe_o follow alt<k>_o_i / alt<k>_oe_i
//                      combinationally (checked 1 ns after a mid-cycle input
//                      change, no clock edge in between, oscillator stopped
//                      too); alt<k>_act_o is exactly the owned pins; inputs
//                      of other and absent functions never reach a pin; the
//                      absent select bits read 0; function number 3 with
//                      ALT_NR=3 drives nothing; pins with ALT_EN=0 keep
//                      OUTPUT / OE; open-drain use passes through.
//                      Skips with ALT_NR=0.
//
// Doc "Alternate functions" (Selection): "The function number of pin n is
// {ALT_SEL1[n], ALT_SEL0[n]} (the absent bits read 0, so it is 0 with
// ALT_NR=1). While ALT_EN[n]=0 the pin is under software control (OUTPUT,
// OE). While ALT_EN[n]=1 and its function number k is below ALT_NR, gpio_o[n]
// and gpio_oe_o[n] follow alt<k>_o_i[n] and alt<k>_oe_i[n]; a function number
// of ALT_NR or more (only possible with ALT_NR=3: value 3) selects nothing
// and the pin is not driven (gpio_oe_o[n]=0, gpio_o[n]=0). alt<k>_act_o[n] is
// 1 while function k owns pin n." "an open-drain one (I2C) drives
// alt<k>_o_i = 0 and alt<k>_oe_i = "pull low"". "The alternate path needs no
// clock: the mux selects are registers, and a running peripheral reaches the
// pins while the GPIO bus clock is gated."
// Doc "Parameters": ALT_NR "Functions ALT_NR and above are absent: their
// alt<k>_* inputs are unused and alt<k>_act_o reads 0."
// Doc "Ports": gpio_o / gpio_oe_o "pass the selected alt<k>_o_i /
// alt<k>_oe_i bit through one AND-OR mux for a pin handed to an alternate
// function".
// Expected values come from a shadow of the registers and the bench's
// alternate-function inputs, so every GPIO_NR (1 included) needs no special
// case; with GPIO_NR=1 the mixed assignments collapse onto pin 0.
//----------------------------------------------------------------------------

`define LONG_TIMEOUT

integer    ii;
integer    kk;
integer    jj;
integer    rot;
integer    ro_c;
reg [31:0] ro_en, ro_sel0, ro_sel1, ro_out, ro_oe;     // shadow (as the DUT holds them)
reg [31:0] ro_s0, ro_s1;
reg [31:0] ro_v, ro_w, ro_m;

wire [31:0] ro_act0 = alt_act32[0];
wire [31:0] ro_act1 = alt_act32[1];
wire [31:0] ro_act2 = alt_act32[2];
wire [31:0] ro_act3 = alt_act32[3];

function [31:0] ro_act;
   input integer k;
   reg   [31:0] s0;
   reg   [31:0] s1;
   begin
      s0 = ((k % 2) != 0)       ? ro_sel0 : ~ro_sel0;
      s1 = (((k / 2) % 2) != 0) ? ro_sel1 : ~ro_sel1;
      if (k >= ALT_NR) ro_act = 32'h0;
      else             ro_act = ro_en & s0 & s1 & GPIO_MASK;
   end
endfunction

function [31:0] ro_exp_o;
   input integer dummy;
   begin
      ro_exp_o = ((ro_out & ~ro_en) | (tb_alt_o[0] & ro_act(0)) | (tb_alt_o[1] & ro_act(1)) |
                  (tb_alt_o[2] & ro_act(2)) | (tb_alt_o[3] & ro_act(3))) & GPIO_MASK;
   end
endfunction

function [31:0] ro_exp_oe;
   input integer dummy;
   begin
      ro_exp_oe = ((ro_oe & ~ro_en) | (tb_alt_oe[0] & ro_act(0)) | (tb_alt_oe[1] & ro_act(1)) |
                   (tb_alt_oe[2] & ro_act(2)) | (tb_alt_oe[3] & ro_act(3))) & GPIO_MASK;
   end
endfunction

task ro_chk_pins;
   input [60*8-1:0] msg;
   begin
      if ((gpio_o32 !== ro_exp_o(0)) || (gpio_oe32 !== ro_exp_oe(0)) ||
          (ro_act0 !== ro_act(0)) || (ro_act1 !== ro_act(1)) ||
          (ro_act2 !== ro_act(2)) || (ro_act3 !== ro_act(3)))
        begin
           $display("ERROR: %0s -- gpio_o 0x%h/0x%h gpio_oe_o 0x%h/0x%h act3..0 0x%h_%h_%h_%h/0x%h_%h_%h_%h (got/expected) %t ns",
                    msg, gpio_o32, ro_exp_o(0), gpio_oe32, ro_exp_oe(0),
                    ro_act3, ro_act2, ro_act1, ro_act0, ro_act(3), ro_act(2), ro_act(1), ro_act(0), $time);
           error = error+1;
        end
      else
        $display("PASS:  %0s -- gpio_o 0x%h gpio_oe_o 0x%h act3..0 0x%h_%h_%h_%h %t ns",
                 msg, gpio_o32, gpio_oe32, ro_act3, ro_act2, ro_act1, ro_act0, $time);
   end
endtask

// Word write with shadow update, pins checked after it
task ro_wr;
   input [31:0] a;
   input [31:0] d;
   begin
      wr(a, d);
      case (a)
        R_OUTPUT  : ro_out  = d & GPIO_MASK;
        R_OE      : ro_oe   = d & GPIO_MASK;
        R_OUT_SET : ro_out  = (ro_out |  d) & GPIO_MASK;
        R_OUT_CLR : ro_out  =  ro_out & ~d;
        R_OUT_TGL : ro_out  = (ro_out ^  d) & GPIO_MASK;
        R_ALT_EN  : if (ALT_NR >= 1) ro_en   = d & GPIO_MASK;
        R_ALT_SEL0: if (ALT_NR >= 2) ro_sel0 = d & GPIO_MASK;
        R_ALT_SEL1: if (ALT_NR >= 3) ro_sel1 = d & GPIO_MASK;
        default   : ;
      endcase
      ro_chk_pins("pins after a register write");
   end
endtask

// Select masks putting function number f on every pin
task ro_all_fn;
   input integer f;
   begin
      ro_s0 = ((f % 2) != 0)       ? 32'hFFFFFFFF : 32'h0;
      ro_s1 = (((f / 2) % 2) != 0) ? 32'hFFFFFFFF : 32'h0;
   end
endtask

// Select masks giving pin n the function number (n + r) % 4
task ro_mix_fn;
   input integer r;
   integer       n;
   begin
      ro_s0 = 32'h0;
      ro_s1 = 32'h0;
      for (n = 0; n < 32; n = n + 1)
        begin
           if ((((n + r) % 4) % 2) != 0)       ro_s0 = ro_s0 | (32'h1 << n);
           if (((((n + r) % 4) / 2) % 2) != 0) ro_s1 = ro_s1 | (32'h1 << n);
        end
   end
endtask

// Change function k's inputs at a random point inside a clock cycle, check
// 1 ns later with no clock edge in between
task ro_drive_chk;
   input integer k;
   input  [31:0] o;
   input  [31:0] oe;
   begin
      @(posedge free_clk);
      ro_c = 2 + ($urandom % 43);
      if (ro_c >= 25) ro_c = ro_c + 1;             // never on the falling edge
      #(ro_c);
      ro_c = aon_cnt;
      alt_drive(k, o, oe);
      #1;
      chk(aon_cnt == ro_c, "alternate input checked with no clock edge in between");
      ro_chk_pins("pins follow the alternate inputs at once");
   end
endtask

initial
   begin
      ro_en = 32'h0; ro_sel0 = 32'h0; ro_sel1 = 32'h0; ro_out = 32'h0; ro_oe = 32'h0;
      wait_reset_done(5);
      if (ALT_NR == 0)
        tb_skip_finish("|   ALT_NR=0: no alternate function to route    |");

      ro_wr(R_OUTPUT, 32'hC3A55A3C);
      ro_wr(R_OE,     32'h9696F00F);

      $display(" ===============================================");
      $display("|   EVERY PIN TO ONE FUNCTION                   |");
      $display(" ===============================================");
      for (kk = 0; kk < ALT_NR; kk = kk + 1)
        begin
           $display("--- function %0d ---", kk);
           ro_wr(R_ALT_EN, 32'h0);
           ro_all_fn(kk);
           ro_wr(R_ALT_SEL0, ro_s0);
           ro_wr(R_ALT_SEL1, ro_s1);
           ro_wr(R_ALT_EN, 32'hFFFFFFFF);
           chk32(ro_act(kk), GPIO_MASK, "shadow: function owns every pin");
           for (ii = 0; ii < 8; ii = ii + 1)
             begin
                case (ii)
                  0:       begin ro_v = 32'hFFFFFFFF; ro_w = 32'hFFFFFFFF; end
                  1:       begin ro_v = 32'h00000000; ro_w = 32'h00000000; end
                  2:       begin ro_v = 32'hFFFFFFFF; ro_w = 32'h00000000; end
                  3:       begin ro_v = 32'h00000000; ro_w = 32'hFFFFFFFF; end
                  default: begin ro_v = $urandom;     ro_w = $urandom;     end
                endcase
                ro_drive_chk(kk, ro_v, ro_w);
                chk32(gpio_o32,  ro_v & GPIO_MASK, "gpio_o = alt<k>_o_i on every pin");
                chk32(gpio_oe32, ro_w & GPIO_MASK, "gpio_oe_o = alt<k>_oe_i on every pin");
                // The other functions (present or absent) move: no effect
                for (jj = 0; jj < 4; jj = jj + 1)
                  if (jj != kk)
                    ro_drive_chk(jj, (($urandom % 2) ? 32'hFFFFFFFF : ~ro_v), (($urandom % 2) ? 32'hFFFFFFFF : ~ro_w));
                chk32(gpio_o32,  ro_v & GPIO_MASK, "other functions do not reach gpio_o");
                chk32(gpio_oe32, ro_w & GPIO_MASK, "other functions do not reach gpio_oe_o");
             end
        end

      $display(" ===============================================");
      $display("|   MIXED ASSIGNMENTS, PART UNDER SOFTWARE      |");
      $display(" ===============================================");
      for (rot = 0; rot < 4; rot = rot + 1)
        for (ii = 0; ii < 3; ii = ii + 1)
          begin
             ro_mix_fn(rot);
             ro_wr(R_ALT_SEL0, ro_s0);
             ro_wr(R_ALT_SEL1, ro_s1);
             case (ii)
               0:       ro_wr(R_ALT_EN, 32'hFFFFFFFF);
               1:       ro_wr(R_ALT_EN, 32'h0F0F0F0F | pbit(rot));
               default: ro_wr(R_ALT_EN, $urandom);
             endcase
             for (jj = 0; jj < 6; jj = jj + 1)
               ro_drive_chk($urandom % 4, $urandom, $urandom);
             // Software side of the pins left to OUTPUT / OE
             ro_wr(R_OUTPUT, $urandom);
             ro_wr(R_OE,     $urandom);
             ro_wr(R_OUT_TGL, 32'hFFFFFFFF);
             ro_wr(R_OUT_SET, $urandom);
             ro_wr(R_OUT_CLR, $urandom);
          end

      $display(" ===============================================");
      $display("|   ABSENT FUNCTIONS AND SELECT BITS            |");
      $display(" ===============================================");
      // Present functions drive 0, absent ones all-ones: nothing of the
      // absent ones may appear
      ro_wr(R_ALT_EN, 32'hFFFFFFFF);
      for (kk = 0; kk < 4; kk = kk + 1)
        if (kk < ALT_NR) ro_drive_chk(kk, 32'h0, 32'h0);
        else             ro_drive_chk(kk, 32'hFFFFFFFF, 32'hFFFFFFFF);
      for (rot = 0; rot < 4; rot = rot + 1)
        begin
           ro_all_fn(rot);
           ro_wr(R_ALT_SEL0, ro_s0);
           ro_wr(R_ALT_SEL1, ro_s1);
           chk32(gpio_o32,  32'h0, "absent function inputs never reach gpio_o");
           chk32(gpio_oe32, 32'h0, "absent function inputs never reach gpio_oe_o");
        end
      chk32(ro_act0 & {32{ALT_NR < 1}} | ro_act1 & {32{ALT_NR < 2}} |
            ro_act2 & {32{ALT_NR < 3}} | ro_act3 & {32{ALT_NR < 4}}, 32'h0, "absent alt<k>_act_o read 0");
      // Every function all-ones; number 3 everywhere
      for (kk = 0; kk < 4; kk = kk + 1)
        ro_drive_chk(kk, 32'hFFFFFFFF, 32'hFFFFFFFF);
      ro_wr(R_ALT_SEL0, 32'hFFFFFFFF);
      ro_wr(R_ALT_SEL1, 32'hFFFFFFFF);
      if (ALT_NR == 3)
        begin
           chk32(gpio_o32,  32'h0, "ALT_NR=3, function number 3: gpio_o = 0");
           chk32(gpio_oe32, 32'h0, "ALT_NR=3, function number 3: gpio_oe_o = 0");
           chk32(ro_act0 | ro_act1 | ro_act2 | ro_act3, 32'h0, "ALT_NR=3, function number 3: no act bit");
        end
      else if (ALT_NR == 4)
        chk32(ro_act3, GPIO_MASK, "ALT_NR=4, function number 3 owns every pin");
      else
        // The absent select bits read 0: function number 1 (ALT_NR=2) or 0 (ALT_NR=1)
        chk32((ALT_NR == 2) ? ro_act1 : ro_act0, GPIO_MASK, "absent select bits read 0");
      // Pins handed to number 3 at ALT_NR=3 next to pins under software
      ro_wr(R_ALT_EN, 32'h00FF00FF | pbit(0));
      ro_wr(R_OUTPUT, 32'hFFFFFFFF);
      ro_wr(R_OE,     32'hFFFFFFFF);

      $display(" ===============================================");
      $display("|   OPEN-DRAIN USE                              |");
      $display(" ===============================================");
      for (kk = 0; kk < ALT_NR; kk = kk + 1)
        begin
           ro_wr(R_ALT_EN, 32'h0);
           ro_all_fn(kk);
           ro_wr(R_ALT_SEL0, ro_s0);
           ro_wr(R_ALT_SEL1, ro_s1);
           ro_m = 32'hAAAA5555 | pbit(GPIO_NR - 1);
           ro_wr(R_ALT_EN, ro_m);
           for (ii = 0; ii < 8; ii = ii + 1)
             begin
                ro_v = (ii < 2) ? ((ii == 0) ? 32'hFFFFFFFF : 32'h0) : $urandom;
                ro_drive_chk(kk, 32'h0, ro_v);
                chk32(gpio_o32 & ro_m,  32'h0,            "open drain: handed pins gpio_o = 0");
                chk32(gpio_oe32 & ro_m, ro_v & ro_m & GPIO_MASK, "open drain: handed pins gpio_oe_o = pull low");
                chk32(gpio_o32 & ~ro_m, GPIO_MASK & ~ro_m, "open drain: other pins keep OUTPUT");
             end
        end

      $display(" ===============================================");
      $display("|   NO CLOCK NEEDED                             |");
      $display(" ===============================================");
      ro_mix_fn(1);
      ro_wr(R_ALT_SEL0, ro_s0);
      ro_wr(R_ALT_SEL1, ro_s1);
      ro_wr(R_ALT_EN, 32'hFFFFFFFF);
      osc_stop;
      ro_c = aon_cnt;
      for (ii = 0; ii < 8; ii = ii + 1)
        begin
           @(posedge free_clk);
           #10;
           alt_drive(ii % 4, $urandom, $urandom);
           #1;
           ro_chk_pins("oscillator stopped: pins follow the alternate inputs");
        end
      chk(aon_cnt == ro_c, "no pclk_aon edge while the oscillator is stopped");
      osc_start;
      cycles(2);
      ro_chk_pins("oscillator restarted");

      ro_wr(R_ALT_EN, 32'h0);
      @(posedge free_clk);
      #10;
      for (kk = 0; kk < 4; kk = kk + 1)
        alt_drive(kk, 32'h0, 32'h0);
      cycles(20);
      stimulus_done = 1;
   end
