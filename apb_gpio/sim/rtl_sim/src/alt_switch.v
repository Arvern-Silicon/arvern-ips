//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    alt_switch
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : alt_switch.v
// Module Description : Hand-over and release of pins: function numbers set
//                      while ALT_EN=0, then one ALT_EN write; the pins are
//                      sampled every half cycle around the write and must go
//                      from OUTPUT / OE straight to the chosen function on a
//                      single clock edge, the one ending the write's data
//                      phase (and back on release); OUTPUT / OE / OUT_SET /
//                      OUT_CLR / OUT_TGL writes while handed over leave the
//                      handed pins alone, are kept, and appear on release;
//                      an ALT_SEL change while ALT_EN=1 ends on the new
//                      function. Skips with ALT_NR=0.
//
// Doc "Alternate functions" (Switching): "Set the function number while
// ALT_EN is 0 for those pins, then hand them over with one write to ALT_EN:
// the pins go straight from OUTPUT/OE to the chosen function. Changing
// ALT_SEL0/ALT_SEL1 while ALT_EN is 1 switches at once and, since the two
// registers are written separately, may select another function for the
// cycles in between." (Software registers): "OUTPUT and OE keep their value
// and stay writable (including through OUT_SET, OUT_CLR, OUT_TGL) while a pin
// is handed over, and take effect again when ALT_EN[n] returns to 0."
// Doc "Interrupts" (Handler sequence): "The write takes effect at the end of
// its ACCESS cycle" -- read here as the rule for every register write, so the
// switch is expected on the rising edge that ends the ALT_EN write's ACCESS
// cycle: apb_write(0, ...) returns 1 ns after the SETUP edge, the ACCESS
// cycle completes at once (PREADY high, the bench checks it), and the next
// rising edge ends it -- the same reading as output_oe_rdwr for OUTPUT / OE.
// "No other value in between" is checked on sample points (every edge + 1 ns
// and every falling edge) and by recording the simulation times at which the
// outputs change: all changes must fall on that one edge's timestamp
// (zero-delay glitches within it are not judged, the document claims no
// glitch-freedom). For an ALT_SEL change with ALT_EN=1 only the final state
// is checked.
//----------------------------------------------------------------------------

`define LONG_TIMEOUT

integer    ii;
integer    kk;
integer    jj;
integer    sw_nchg;
realtime   sw_tchg;
realtime   sw_tedge;
reg        sw_rec;                                     // record output-change times
reg        sw_hold;                                    // handed pins must not move
reg [31:0] sw_hmask;
reg [31:0] sw_ho, sw_hoe;
reg [31:0] sw_en, sw_sel0, sw_sel1, sw_out, sw_oe;     // shadow (as the DUT holds them)
reg [31:0] sw_s0, sw_s1;
reg [31:0] sw_bo, sw_boe, sw_ba0, sw_ba1, sw_ba2, sw_ba3;
reg [31:0] sw_new;
reg        sw_moves;

wire [31:0] sw_act0 = alt_act32[0];
wire [31:0] sw_act1 = alt_act32[1];
wire [31:0] sw_act2 = alt_act32[2];
wire [31:0] sw_act3 = alt_act32[3];

function [31:0] sw_act;
   input integer k;
   reg   [31:0] s0;
   reg   [31:0] s1;
   begin
      s0 = ((k % 2) != 0)       ? sw_sel0 : ~sw_sel0;
      s1 = (((k / 2) % 2) != 0) ? sw_sel1 : ~sw_sel1;
      if (k >= ALT_NR) sw_act = 32'h0;
      else             sw_act = sw_en & s0 & s1 & GPIO_MASK;
   end
endfunction

function [31:0] sw_exp_o;
   input integer dummy;
   begin
      sw_exp_o = ((sw_out & ~sw_en) | (tb_alt_o[0] & sw_act(0)) | (tb_alt_o[1] & sw_act(1)) |
                  (tb_alt_o[2] & sw_act(2)) | (tb_alt_o[3] & sw_act(3))) & GPIO_MASK;
   end
endfunction

function [31:0] sw_exp_oe;
   input integer dummy;
   begin
      sw_exp_oe = ((sw_oe & ~sw_en) | (tb_alt_oe[0] & sw_act(0)) | (tb_alt_oe[1] & sw_act(1)) |
                   (tb_alt_oe[2] & sw_act(2)) | (tb_alt_oe[3] & sw_act(3))) & GPIO_MASK;
   end
endfunction

task sw_chk_pins;
   input [60*8-1:0] msg;
   begin
      if ((gpio_o32 !== sw_exp_o(0)) || (gpio_oe32 !== sw_exp_oe(0)) ||
          (sw_act0 !== sw_act(0)) || (sw_act1 !== sw_act(1)) ||
          (sw_act2 !== sw_act(2)) || (sw_act3 !== sw_act(3)))
        begin
           $display("ERROR: %0s -- gpio_o 0x%h/0x%h gpio_oe_o 0x%h/0x%h act3..0 0x%h_%h_%h_%h/0x%h_%h_%h_%h (got/expected) %t ns",
                    msg, gpio_o32, sw_exp_o(0), gpio_oe32, sw_exp_oe(0),
                    sw_act3, sw_act2, sw_act1, sw_act0, sw_act(3), sw_act(2), sw_act(1), sw_act(0), $time);
           error = error+1;
        end
      else
        $display("PASS:  %0s -- gpio_o 0x%h gpio_oe_o 0x%h %t ns", msg, gpio_o32, gpio_oe32, $time);
   end
endtask

// Exact values (used for the before / after states of a switch)
task sw_chk_state;
   input  [31:0] o;
   input  [31:0] oe;
   input  [31:0] a0;
   input  [31:0] a1;
   input  [31:0] a2;
   input  [31:0] a3;
   input [60*8-1:0] msg;
   begin
      if ((gpio_o32 !== o) || (gpio_oe32 !== oe) || (sw_act0 !== a0) || (sw_act1 !== a1) ||
          (sw_act2 !== a2) || (sw_act3 !== a3))
        begin
           $display("ERROR: %0s -- gpio_o 0x%h/0x%h gpio_oe_o 0x%h/0x%h act3..0 0x%h_%h_%h_%h/0x%h_%h_%h_%h (got/expected) %t ns",
                    msg, gpio_o32, o, gpio_oe32, oe, sw_act3, sw_act2, sw_act1, sw_act0, a3, a2, a1, a0, $time);
           error = error+1;
        end
   end
endtask

// Output-change recorder: number of distinct timestamps with a change
always @(gpio_o32 or gpio_oe32 or sw_act0 or sw_act1 or sw_act2 or sw_act3)
  if ((sw_rec === 1'b1) && (presetn === 1'b1) && ($realtime != sw_tchg))
    begin
       sw_nchg = sw_nchg + 1;
       sw_tchg = $realtime;
    end

// Handed pins frozen
always @(gpio_o32 or gpio_oe32)
  if ((sw_hold === 1'b1) && (presetn === 1'b1) &&
      ((((gpio_o32 ^ sw_ho) | (gpio_oe32 ^ sw_hoe)) & sw_hmask) != 32'h0))
    begin
       $display("ERROR: a handed-over pin moved on a software register write -- gpio_o=0x%h gpio_oe_o=0x%h mask=0x%h %t ns",
                gpio_o32, gpio_oe32, sw_hmask, $time);
       error = error+1;
    end

// Word write with shadow update, pins checked after it
task sw_wr;
   input [31:0] a;
   input [31:0] d;
   begin
      wr(a, d);
      case (a)
        R_OUTPUT  : sw_out  = d & GPIO_MASK;
        R_OE      : sw_oe   = d & GPIO_MASK;
        R_OUT_SET : sw_out  = (sw_out |  d) & GPIO_MASK;
        R_OUT_CLR : sw_out  =  sw_out & ~d;
        R_OUT_TGL : sw_out  = (sw_out ^  d) & GPIO_MASK;
        R_ALT_EN  : if (ALT_NR >= 1) sw_en   = d & GPIO_MASK;
        R_ALT_SEL0: if (ALT_NR >= 2) sw_sel0 = d & GPIO_MASK;
        R_ALT_SEL1: if (ALT_NR >= 3) sw_sel1 = d & GPIO_MASK;
        default   : ;
      endcase
      sw_chk_pins("pins after a register write");
   end
endtask

task sw_all_fn;
   input integer f;
   begin
      sw_s0 = ((f % 2) != 0)       ? 32'hFFFFFFFF : 32'h0;
      sw_s1 = (((f / 2) % 2) != 0) ? 32'hFFFFFFFF : 32'h0;
   end
endtask

// Pin n gets the present function number (n + r) % ALT_NR
task sw_mix_fn;
   input integer r;
   integer       n;
   integer       f;
   begin
      sw_s0 = 32'h0;
      sw_s1 = 32'h0;
      for (n = 0; n < 32; n = n + 1)
        begin
           f = (n + r) % ALT_NR;
           if ((f % 2) != 0)       sw_s0 = sw_s0 | (32'h1 << n);
           if (((f / 2) % 2) != 0) sw_s1 = sw_s1 | (32'h1 << n);
        end
   end
endtask

// One ALT_EN word write with the switch timed: before-state up to and
// through the ACCESS cycle, after-state from the edge ending it, and all
// output changes on that edge's timestamp.
task sw_timed_en;
   input [31:0] d;
   begin
      sw_chk_pins("before the ALT_EN write");
      sw_bo  = gpio_o32;  sw_boe = gpio_oe32;
      sw_ba0 = sw_act0;   sw_ba1 = sw_act1;   sw_ba2 = sw_act2;   sw_ba3 = sw_act3;
      sw_nchg = 0;
      sw_tchg = -1;
      sw_rec  = 1'b1;
      for (jj = 0; jj < 2; jj = jj + 1)
        begin
           @(negedge free_clk);
           sw_chk_state(sw_bo, sw_boe, sw_ba0, sw_ba1, sw_ba2, sw_ba3, "before the ALT_EN write (falling edge)");
           @(posedge free_clk);
           #1;
           sw_chk_state(sw_bo, sw_boe, sw_ba0, sw_ba1, sw_ba2, sw_ba3, "before the ALT_EN write (rising edge)");
        end
      apb_write(0, MACHINE, R_ALT_EN, d, SZ_W, OK);              // returns in the ACCESS cycle
      sw_chk_state(sw_bo, sw_boe, sw_ba0, sw_ba1, sw_ba2, sw_ba3, "ALT_EN write: unchanged after the SETUP cycle");
      @(negedge free_clk);
      sw_chk_state(sw_bo, sw_boe, sw_ba0, sw_ba1, sw_ba2, sw_ba3, "ALT_EN write: unchanged during the ACCESS cycle");
      @(posedge free_clk);
      sw_tedge = $realtime;
      #1;
      if (ALT_NR >= 1) sw_en = d & GPIO_MASK;
      sw_chk_pins("ALT_EN write: switched on the edge ending the ACCESS cycle");
      for (jj = 0; jj < 4; jj = jj + 1)
        begin
           @(negedge free_clk);
           sw_chk_pins("after the ALT_EN write (falling edge)");
           @(posedge free_clk);
           #1;
           sw_chk_pins("after the ALT_EN write (rising edge)");
        end
      sw_rec = 1'b0;
      sw_moves = (sw_bo !== gpio_o32) || (sw_boe !== gpio_oe32) || (sw_ba0 !== sw_act0) ||
                 (sw_ba1 !== sw_act1) || (sw_ba2 !== sw_act2) || (sw_ba3 !== sw_act3);
      if (sw_moves)
        begin
           if ((sw_nchg != 1) || (sw_tchg != sw_tedge))
             begin
                $display("ERROR: outputs changed at %0d timestamp(s), last at %0t, expected once at %0t (edge ending the ACCESS cycle) %t ns",
                         sw_nchg, sw_tchg, sw_tedge, $time);
                error = error+1;
             end
           else
             $display("PASS:  single switch on the edge ending the ALT_EN ACCESS cycle %t ns", $time);
        end
      else
        chk(sw_nchg == 0, "no output change when the hand-over changes nothing");
   end
endtask

// Function inputs fresh and the software side the complement of the
// function on every pin, so every pin's o and oe flip on the switch
task sw_contrast;
   input integer k;
   begin
      @(posedge free_clk);
      #10;
      for (jj = 0; jj < 4; jj = jj + 1)
        alt_drive(jj, $urandom, $urandom);
      #1;
      sw_chk_pins("fresh alternate inputs");
      sw_wr(R_OUTPUT, ~tb_alt_o[k]);
      sw_wr(R_OE,     ~tb_alt_oe[k]);
   end
endtask

initial
   begin
      sw_rec  = 1'b0;
      sw_hold = 1'b0;
      sw_tchg = -1;
      sw_nchg = 0;
      sw_en = 32'h0; sw_sel0 = 32'h0; sw_sel1 = 32'h0; sw_out = 32'h0; sw_oe = 32'h0;
      wait_reset_done(5);
      if (ALT_NR == 0)
        tb_skip_finish("|   ALT_NR=0: no alternate function to switch   |");

      $display(" ===============================================");
      $display("|   HAND-OVER AND RELEASE, EVERY PIN            |");
      $display(" ===============================================");
      for (kk = 0; kk < ALT_NR; kk = kk + 1)
        begin
           $display("--- function %0d ---", kk);
           sw_contrast(kk);
           sw_all_fn(kk);
           sw_wr(R_ALT_SEL0, sw_s0);
           sw_wr(R_ALT_SEL1, sw_s1);
           sw_timed_en(32'hFFFFFFFF);
           chk32(gpio_o32,  tb_alt_o[kk]  & GPIO_MASK, "handed over: gpio_o = alt<k>_o_i");
           chk32(gpio_oe32, tb_alt_oe[kk] & GPIO_MASK, "handed over: gpio_oe_o = alt<k>_oe_i");
           sw_timed_en(32'h0);
           chk32(gpio_o32,  ~tb_alt_o[kk]  & GPIO_MASK, "released: gpio_o = OUTPUT");
           chk32(gpio_oe32, ~tb_alt_oe[kk] & GPIO_MASK, "released: gpio_oe_o = OE");
        end

      $display(" ===============================================");
      $display("|   PARTIAL HAND-OVER, MIXED FUNCTIONS          |");
      $display(" ===============================================");
      for (ii = 0; ii < 6; ii = ii + 1)
        begin
           sw_contrast(ii % ALT_NR);
           sw_mix_fn(ii);
           sw_wr(R_ALT_SEL0, sw_s0);
           sw_wr(R_ALT_SEL1, sw_s1);
           sw_new = $urandom | pbit(ii);
           sw_timed_en(sw_new);                          // part of the pins
           sw_timed_en(sw_new | $urandom);               // more pins (already handed ones stay)
           sw_timed_en(sw_en & $urandom);                // partial release
           sw_timed_en(32'h0);                           // full release
        end

      $display(" ===============================================");
      $display("|   SOFTWARE WRITES WHILE HANDED OVER           |");
      $display(" ===============================================");
      for (ii = 0; ii < 4; ii = ii + 1)
        begin
           sw_contrast(ii % ALT_NR);
           sw_mix_fn(ii + 1);
           sw_wr(R_ALT_SEL0, sw_s0);
           sw_wr(R_ALT_SEL1, sw_s1);
           sw_new = (ii == 0) ? 32'hFFFFFFFF : ($urandom | pbit(GPIO_NR - 1));
           sw_timed_en(sw_new);
           sw_hmask = sw_en;
           sw_ho    = gpio_o32;
           sw_hoe   = gpio_oe32;
           sw_hold  = 1'b1;
           sw_wr(R_OUTPUT, $urandom);
           sw_wr(R_OE,     $urandom);
           sw_wr(R_OUT_SET, $urandom);
           sw_wr(R_OUT_CLR, $urandom);
           sw_wr(R_OUT_TGL, $urandom);
           apb_write(1, MACHINE, R_OUTPUT + 1, 8'hA5, SZ_B, OK);
           sw_out = ((sw_out & ~32'h0000FF00) | 32'h0000A500) & GPIO_MASK;
           apb_write(1, MACHINE, R_OE + 2, 16'h5AC3, SZ_H, OK);
           sw_oe  = ((sw_oe & ~32'hFFFF0000) | 32'h5AC30000) & GPIO_MASK;
           sw_chk_pins("handed pins unchanged by narrow software writes");
           sw_hold  = 1'b0;
           rd(R_OUTPUT, sw_out);
           rd(R_OE,     sw_oe);
           sw_timed_en(32'h0);                           // the new OUTPUT / OE appear
           chk32(gpio_o32,  sw_out, "released: gpio_o = OUTPUT written while handed over");
           chk32(gpio_oe32, sw_oe,  "released: gpio_oe_o = OE written while handed over");
        end

      if (ALT_NR >= 2)
        begin
           $display(" ===============================================");
           $display("|   ALT_SEL CHANGE WITH ALT_EN=1                |");
           $display(" ===============================================");
           sw_contrast(0);
           sw_wr(R_ALT_EN, 32'hFFFFFFFF);
           for (ii = 0; ii < 4; ii = ii + 1)
             for (kk = 0; kk < 4; kk = kk + 1)
               begin
                  // from function ii to function kk on every pin (both < 4)
                  sw_all_fn(ii);
                  wr(R_ALT_SEL0, sw_s0);
                  if (ALT_NR >= 3) wr(R_ALT_SEL1, sw_s1);
                  sw_sel0 = sw_s0 & GPIO_MASK;
                  sw_sel1 = (ALT_NR >= 3) ? (sw_s1 & GPIO_MASK) : 32'h0;
                  sw_chk_pins("ALT_SEL set while handed over");
                  sw_all_fn(kk);
                  wr(R_ALT_SEL0, sw_s0);
                  if (ALT_NR >= 3) wr(R_ALT_SEL1, sw_s1);
                  sw_sel0 = sw_s0 & GPIO_MASK;
                  sw_sel1 = (ALT_NR >= 3) ? (sw_s1 & GPIO_MASK) : 32'h0;
                  sw_chk_pins("ALT_SEL change while handed over: final function");
               end
           // Mixed per-pin change
           for (ii = 0; ii < 4; ii = ii + 1)
             begin
                sw_mix_fn(ii);
                wr(R_ALT_SEL1, sw_s1);                    // intermediate function not judged
                if (ALT_NR >= 3) sw_sel1 = sw_s1 & GPIO_MASK;
                sw_wr(R_ALT_SEL0, sw_s0);
                sw_chk_pins("mixed ALT_SEL change while handed over: final functions");
             end
           sw_wr(R_ALT_EN, 32'h0);
        end
      else
        $display("ALT_NR=1: no ALT_SEL register, no in-place function change");

      @(posedge free_clk);
      #10;
      for (kk = 0; kk < 4; kk = kk + 1)
        alt_drive(kk, 32'h0, 32'h0);
      cycles(20);
      stimulus_done = 1;
   end
