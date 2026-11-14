//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    random_stress
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : random_stress.v
// Module Description : Randomised pins and bus traffic, checked every cycle
//                      against the bench reference model (gpio_model.v):
//                      gpio_o, gpio_oe_o, irq_o, irq_any_o, every read value,
//                      every response.
//
// Pins: single-pin toggles, whole-port patterns and one-cycle pulses, at
// random intervals, #10 after a clock edge; the pad loop-back is switched on
// and off. Bus: word / half-word / byte writes and reads of every register
// and of unmapped words, OUT_SET/CLR/TGL, OE_SET/CLR, IRQ_EN_SET/CLR, W1C,
// IRQ_EN, WAKE_EN, mode and IN_EN writes (sparse values, sometimes
// all-zero), random MDELEG values written from Machine mode, U/S-mode
// accesses (admitted, refused with PSLVERR or dropped silently, per the
// current MDELEG), back-to-back bursts,
// transfers started mid-cycle, idle gaps (the bus clock
// stops, the input path keeps running on pclk_aon), tb_pclk_force toggles,
// oscillator-off periods with pin activity (gpio_wake_o checked), and
// occasional mid-test resets.
//
// The pins are frozen around every mode-register and IN_EN write, from a
// few cycles before it to past the flush: a mode write landing on the same
// edge as a detected edge is not specified, and the model does not compare
// irq_o / IRQ_PEND / INPUT / wake right after an IN_EN change (m_fuzzy).
//----------------------------------------------------------------------------

`define LONG_TIMEOUT

integer    ii;
integer    nn;
integer    op;
integer    kind;
integer    pp;
integer    n_ops;
integer    n_burst;
reg        pin_freeze;
reg        stress_run;
reg [31:0] v;
reg [31:0] a;
reg  [1:0] sz;
reg  [1:0] md;

// Random aligned address inside register 'idx' (reg_addr() order; >= REG_NR = unmapped)
task pick_access;
   input integer idx;
   begin
      sz = $urandom % 3;
      a  = reg_addr(idx);
      a  = a + ((sz == SZ_B) ? ($urandom % 4) : (sz == SZ_H) ? (2*($urandom % 2)) : 0);
   end
endtask

function [31:0] sparse;
   input integer dummy;
   reg   [31:0] r;
   begin
      r = $urandom;
      case ($urandom % 4)
        0:       sparse = 32'h0;
        1:       sparse = r & $urandom & $urandom;
        2:       sparse = 32'h1 << ($urandom % GPIO_NR);
        default: sparse = r;
      endcase
   end
endfunction

// Mode-register write with the pins frozen around it
task mode_write;
   begin
      apb_flush;
      pin_freeze = 1'b1;
      cycles(3);
      case ($urandom % 7)
        0:       a = R_IRQ_RISE;
        1:       a = R_IRQ_FALL;
        2:       a = R_IRQ_HIGH;
        3:       a = R_IRQ_LOW;
        4:       a = R_MDELEG;
        default: a = R_IN_EN;
      endcase
      if (a == R_MDELEG)
        apb_write(1, MACHINE, a + ($urandom % 2), $urandom, ($urandom % 2) ? SZ_B : SZ_W, OK);
      else if (($urandom % 4) == 0)
        apb_write(1, MACHINE, a + 2*($urandom % 2), sparse(0), SZ_H, OK);
      else
        apb_write(1, MACHINE, a, sparse(0), SZ_W, OK);
      cycles(2*L_IN + 6);
      pin_freeze = 1'b0;
   end
endtask

// One non-mode operation (blocking or not)
task one_op;
   input blocking;
   begin
      op = $urandom % 20;
      v  = $urandom;
      md = MACHINE;
      if (op < 3)                                   // OUTPUT / OE / IRQ_EN / WAKE_EN
        begin
           pick_access(1 + ($urandom % 2));
           if (op == 2) pick_access(($urandom % 2) ? 6 : 14);
           apb_write(blocking, md, a, v, sz, OK);
        end
      else if (op < 6)                              // OUT_SET / OUT_CLR / OUT_TGL / OE_* / IRQ_EN_*
        begin
           pick_access(($urandom % 2) ? (3 + ($urandom % 3)) : (17 + ($urandom % 4)));
           apb_write(blocking, md, a, v, sz, OK);
        end
      else if (op < 8)                              // W1C
        begin
           pick_access(11);
           apb_write(blocking, md, a, (($urandom % 2) ? v : 32'hFFFFFFFF), sz, OK);
        end
      else if (op < 15)                             // read any register / unmapped
        begin
           pick_access($urandom % (REG_NR + 1));
           apb_read(blocking, md, a, 32'h0, sz, 1'b0, OK);
        end
      else if (op < 16)                             // unmapped write
        begin
           pick_access(REG_NR + ($urandom % 4));
           if (a >= GPIO_BASE + WIN_SIZE) a = R_FIRST_UNMAP;
           apb_write(blocking, md, a, v, sz, OK);
        end
      else                                          // U / S-mode access to a non-mode register
        begin
           case ($urandom % 3)
             0:       md = USER;
             1:       md = USER_S;
             default: md = SUPERVISOR;
           endcase
           case ($urandom % 9)
             0:       pick_access(0);
             1:       pick_access(1);
             2:       pick_access(3 + ($urandom % 3));
             3:       pick_access(6);
             4:       pick_access(11);
             5:       pick_access(14);
             6:       pick_access(15 + ($urandom % 6));
             7:       begin pick_access(0); a = R_MDELEG + (a - R_INPUT); end
             default: pick_access(12);
           endcase
           if (op < 18)
             apb_write(blocking, md, a, v, sz, exp_resp_of(1'b1, md, a));
           else
             apb_read(blocking, md, a, 32'h0, sz, 1'b0, exp_resp_of(1'b0, md, a));
        end
   end
endtask

// Pin driver
initial
   begin
      pin_freeze = 1'b0;
      stress_run = 1'b0;
      wait (stress_run === 1'b1);
      while (stress_run)
        begin
           repeat (1 + ($urandom % 6)) @(posedge free_clk);
           #10;
           if (!pin_freeze && stress_run && (presetn === 1'b1))
             begin
                kind = $urandom % 10;
                if (kind < 7)
                  gpio_ext = gpio_ext ^ pbit($urandom % GPIO_NR);
                else if (kind < 9)
                  gpio_ext = $urandom;
                else
                  begin
                     pp = $urandom % GPIO_NR;
                     gpio_ext = gpio_ext ^ pbit(pp);
                     @(posedge free_clk);
                     #10;
                     gpio_ext = gpio_ext ^ pbit(pp);
                  end
             end
        end
   end

initial
   begin
      wait_reset_done(5);
      n_ops   = 0;
      n_burst = 0;
      cycles(2);
      model_check_en = 1'b1;
      stress_run     = 1'b1;

      for (ii = 0; ii < 2500; ii = ii + 1)
        begin
           kind = $urandom % 100;
           if (kind < 10)
             mode_write;
           else if (kind < 45)
             one_op(1'b1);
           else if (kind < 70)
             begin                                   // back-to-back burst
                nn = 2 + ($urandom % 5);
                repeat (nn) one_op(1'b0);
                apb_flush;
                n_burst = n_burst + 1;
             end
           else if (kind < 76)
             begin                                   // transfer started mid-cycle, after the bus idled
                apb_flush;
                @(negedge free_clk);
                #($urandom % 20);
                one_op(1'b1);
             end
           else if (kind < 90)
             cycles($urandom % 12);                  // idle: the clock may stop
           else if (kind < 94)
             begin
                @(posedge free_clk);
                #1;
                tb_pclk_force = ~tb_pclk_force;
             end
           else if (kind < 98)
             begin                                   // pad loop-back on / off, pins otherwise still
                apb_flush;
                pin_freeze = 1'b1;
                @(posedge free_clk);
                #10;
                tb_pad_loop = ~tb_pad_loop;
                cycles(1);
                pin_freeze = 1'b0;
             end
           else if ((ii % 500) <= 400)
             begin                                   // oscillator off, pins move, back on
                apb_flush;
                osc_stop;
                repeat (1 + ($urandom % 3))
                  begin
                     repeat (1 + ($urandom % 3)) @(posedge free_clk);
                     #10;
                     if (!pin_freeze) gpio_ext = gpio_ext ^ pbit($urandom % GPIO_NR);
                  end
                cycles(2);
                osc_start;
                cycles(L_IN + 2);
             end
           else
             begin                                   // mid-test reset
                apb_flush;
                tb_reset_pulse(4);
                cycles(2);
             end
           n_ops = n_ops + 1;
        end

      apb_flush;
      stress_run = 1'b0;
      cycles(2*L_IN + 6);
      // Final sweep of every register through the model
      for (ii = 0; ii <= REG_NR; ii = ii + 1)
        apb_read(1, MACHINE, reg_addr(ii), 32'h0, SZ_W, 1'b0, OK);
      cycles(5);
      model_check_en = 1'b0;
      $display("random_stress: %0d steps, %0d bursts, %0d model mismatches", n_ops, n_burst, m_errors);

      cycles(20);
      stimulus_done = 1;
   end
