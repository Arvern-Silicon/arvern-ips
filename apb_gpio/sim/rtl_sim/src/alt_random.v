//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    alt_random
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : alt_random.v
// Module Description : Randomised alternate-function traffic checked every
//                      cycle against the bench reference model (gpio_model.v):
//                      gpio_o, gpio_oe_o, alt<k>_act_o, irq_o, irq_any_o,
//                      gpio_wake_o, every read value and every response.
//
// Bus: word / half-word / byte writes to ALT_EN, ALT_SEL0, ALT_SEL1 (present
// or absent for this ALT_NR), OUTPUT, OE, OUT_SET / OUT_CLR / OUT_TGL,
// IRQ_EN and IRQ_PEND (W1C); reads of every register, the ALT registers and
// IRQ_STAT above them; U / S-mode accesses to the ALT registers (admitted,
// refused with PSLVERR or dropped silently, per MDELEG, which is set to a
// random value before the run); back-to-back bursts, transfers started mid-cycle,
// idle gaps (bus clock stopped). Alternate inputs: all four functions
// (absent ones included) change at random points inside a cycle, never on an
// edge; external pins change #10 after a rising edge; the pad loop-back is
// mostly on, so function-driven pins also feed the input path; oscillator-off
// periods with function and pin activity (the alternate path needs no clock).
//
// IN_EN, the mode registers and WAKE_EN are set once before the checked run
// and never written during it (the model does not compare right after an
// IN_EN change, and a mode write landing on a detected edge is not
// specified). Runs at every ALT_NR, 0 included.
//
// Doc "Alternate functions", "Register map" (ALT_EN / ALT_SEL0 / ALT_SEL1 and
// their ALT_NR conditions), "Ports" (alt<k>_*), as modelled in gpio_model.v.
//----------------------------------------------------------------------------

`define LONG_TIMEOUT

integer    ii;
integer    nn;
integer    kind;
integer    op;
integer    n_ops;
integer    n_alt;
integer    rk;
integer    rdly;
reg        rnd_run;
reg        rnd_freeze;
reg [31:0] v;
reg [31:0] a;
reg  [1:0] sz;
reg  [1:0] md;
reg [31:0] rv_o, rv_oe;

function [31:0] rnd_val;
   input integer dummy;
   reg   [31:0] r;
   begin
      r = $urandom;
      case ($urandom % 6)
        0:       rnd_val = 32'h0;
        1:       rnd_val = 32'hFFFFFFFF;
        2:       rnd_val = 32'h1 << ($urandom % GPIO_NR);
        3:       rnd_val = r & $urandom;
        default: rnd_val = r;
      endcase
   end
endfunction

// Random size / lane inside the word at 'base'
task rnd_access;
   input [31:0] base;
   begin
      sz = $urandom % 3;
      a  = base + ((sz == SZ_B) ? ($urandom % 4) : (sz == SZ_H) ? (2*($urandom % 2)) : 0);
   end
endtask

function [31:0] alt_reg_addr;
   input integer n;
   begin
      case (n)
        0:       alt_reg_addr = R_ALT_EN;
        1:       alt_reg_addr = R_ALT_SEL0;
        2:       alt_reg_addr = R_ALT_SEL1;
        default: alt_reg_addr = R_ALT_SEL1 + 4;
      endcase
   end
endfunction

task one_op;
   input blocking;
   begin
      op = $urandom % 20;
      v  = rnd_val(0);
      md = MACHINE;
      if (op < 7)                                   // ALT registers (and the word above)
        begin
           rnd_access(alt_reg_addr(($urandom % 7 == 0) ? 3 : ($urandom % 3)));
           apb_write(blocking, md, a, v, sz, OK);
        end
      else if (op < 10)                             // OUTPUT / OE / OUT_SET / OUT_CLR / OUT_TGL
        begin
           case ($urandom % 5)
             0:       rnd_access(R_OUTPUT);
             1:       rnd_access(R_OE);
             2:       rnd_access(R_OUT_SET);
             3:       rnd_access(R_OUT_CLR);
             default: rnd_access(R_OUT_TGL);
           endcase
           apb_write(blocking, md, a, v, sz, OK);
        end
      else if (op < 11)                             // IRQ_EN / W1C
        begin
           rnd_access(($urandom % 2) ? R_IRQ_EN : R_IRQ_PEND);
           apb_write(blocking, md, a, v, sz, OK);
        end
      else if (op < 18)                             // reads
        begin
           if ($urandom % 2)
             rnd_access(alt_reg_addr($urandom % 4));
           else
             rnd_access(reg_addr($urandom % (REG_NR + 1)));
           apb_read(blocking, md, a, 32'h0, sz, 1'b0, OK);
        end
      else                                          // U / S-mode access to an ALT register
        begin
           case ($urandom % 3)
             0:       md = USER;
             1:       md = USER_S;
             default: md = SUPERVISOR;
           endcase
           rnd_access(alt_reg_addr($urandom % 3));
           if (op == 18)
             apb_write(blocking, md, a, v, sz, exp_resp_of(1'b1, md, a));
           else
             apb_read(blocking, md, a, 32'h0, sz, 1'b0, exp_resp_of(1'b0, md, a));
        end
   end
endtask

// Alternate-function driver: a random point inside the cycle, never on an edge
initial
   begin
      n_alt   = 0;
      rnd_run = 1'b0;
      wait (rnd_run === 1'b1);
      while (rnd_run)
        begin
           repeat (1 + ($urandom % 4)) @(posedge free_clk);
           rdly = 2 + ($urandom % 44);
           if ((rdly >= 23) && (rdly <= 27)) rdly = 30;  // clear of the falling edge
           #(rdly);
           if (rnd_run && !rnd_freeze && (presetn === 1'b1))
             begin
                rk    = $urandom % 4;
                rv_o  = tb_alt_o[rk];
                rv_oe = tb_alt_oe[rk];
                case ($urandom % 6)
                  0:       rv_o  = rv_o  ^ pbit($urandom % GPIO_NR);
                  1:       rv_oe = rv_oe ^ pbit($urandom % GPIO_NR);
                  2:       begin rv_o = rv_o ^ pbit($urandom % GPIO_NR); rv_oe = rv_oe ^ pbit($urandom % GPIO_NR); end
                  3:       begin rv_o = 32'hFFFFFFFF; rv_oe = 32'hFFFFFFFF; end
                  4:       begin rv_o = 32'h0;        rv_oe = $urandom;     end
                  default: begin rv_o = $urandom;     rv_oe = $urandom;     end
                endcase
                alt_drive(rk, rv_o, rv_oe);
                n_alt = n_alt + 1;
             end
        end
   end

// External pins, #10 after a rising edge
initial
   begin
      wait (rnd_run === 1'b1);
      while (rnd_run)
        begin
           repeat (1 + ($urandom % 8)) @(posedge free_clk);
           #10;
           if (rnd_run && !rnd_freeze && (presetn === 1'b1))
             begin
                if (($urandom % 5) == 0)
                  gpio_ext = $urandom;
                else
                  gpio_ext = gpio_ext ^ pbit($urandom % GPIO_NR);
             end
        end
   end

initial
   begin
      rnd_freeze = 1'b0;
      wait_reset_done(5);
      n_ops = 0;

      // Input path set once, pins still
      tb_pad_loop = 1'b1;
      gpio_ext    = $urandom;
      cycles(2);
      wr(R_IRQ_RISE, 32'h55555555);
      wr(R_IRQ_FALL, 32'h33333333);
      wr(R_IRQ_HIGH, 32'h01000100);
      wr(R_IRQ_LOW,  32'h00800080);
      wr(R_WAKE_EN,  32'h0F0F0F0F | pbit(0));
      wr(R_IRQ_EN,   $urandom);
      inputs_on(32'hFFFFFFFF);
      wr(R_IRQ_PEND, 32'hFFFFFFFF);
      wr(R_MDELEG,   $urandom);
      cycles(2);
      model_check_en = 1'b1;
      rnd_run        = 1'b1;

      for (ii = 0; ii < 2000; ii = ii + 1)
        begin
           kind = $urandom % 100;
           if (kind < 35)
             one_op(1'b1);
           else if (kind < 60)
             begin                                   // back-to-back burst
                nn = 2 + ($urandom % 5);
                repeat (nn) one_op(1'b0);
                apb_flush;
             end
           else if (kind < 66)
             begin                                   // transfer started mid-cycle, after the bus idled
                apb_flush;
                @(negedge free_clk);
                #($urandom % 20);
                one_op(1'b1);
             end
           else if (kind < 70)
             begin                                   // hand-over: function numbers, then ALT_EN
                apb_flush;
                apb_write(1, MACHINE, R_ALT_EN, 32'h0, SZ_W, OK);
                apb_write(1, MACHINE, R_ALT_SEL0, $urandom, SZ_W, OK);
                apb_write(1, MACHINE, R_ALT_SEL1, $urandom, SZ_W, OK);
                apb_write(1, MACHINE, R_ALT_EN, rnd_val(0), SZ_W, OK);
             end
           else if (kind < 88)
             cycles($urandom % 12);                  // idle: the bus clock stops
           else if (kind < 90)
             begin                                   // pad loop-back flip, pins otherwise still
                apb_flush;
                rnd_freeze = 1'b1;
                @(posedge free_clk);
                #10;
                tb_pad_loop = ~tb_pad_loop;
                cycles(1);
                rnd_freeze = 1'b0;
             end
           else if (kind < 92)
             begin                                   // oscillator off, functions and pins move
                apb_flush;
                osc_stop;
                repeat (2 + ($urandom % 4))
                  begin
                     @(posedge free_clk);
                     #10;
                     rk = $urandom % 4;
                     alt_drive(rk, $urandom, $urandom);
                     if (($urandom % 2) == 0)
                       gpio_ext = gpio_ext ^ pbit($urandom % GPIO_NR);
                  end
                cycles(2);
                osc_start;
                cycles(L_IN + 2);
             end
           else
             cycles(1 + ($urandom % 3));
           n_ops = n_ops + 1;
        end

      apb_flush;
      rnd_run = 1'b0;
      cycles(2*L_IN + 6);
      // Final sweep through the model
      for (ii = 0; ii <= REG_NR; ii = ii + 1)
        apb_read(1, MACHINE, reg_addr(ii), 32'h0, SZ_W, 1'b0, OK);
      for (ii = 0; ii < 4; ii = ii + 1)
        apb_read(1, MACHINE, alt_reg_addr(ii), 32'h0, SZ_W, 1'b0, OK);
      cycles(5);
      model_check_en = 1'b0;
      $display("alt_random: %0d steps, %0d alternate-input changes, %0d model mismatches", n_ops, n_alt, m_errors);

      cycles(20);
      stimulus_done = 1;
   end
