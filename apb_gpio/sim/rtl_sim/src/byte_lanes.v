//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    byte_lanes
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : byte_lanes.v
// Module Description : Byte and half-word writes to every RW register (IN_EN
//                      and WAKE_EN included) update
//                      only their lanes; narrow reads return the whole word;
//                      a narrow W1C to IRQ_PEND clears only its lanes.
//
// Doc "Register map": "Byte and half-word writes update only the addressed
// byte lanes; reads always return the whole word." IRQ_PEND is RW1C.
// The BFM fills unstrobed lanes of pwdata with random junk.
//----------------------------------------------------------------------------

integer    rr;
integer    ii;
reg [31:0] addr;
reg [31:0] exp_v;
reg [31:0] val;

function [31:0] rw_reg;
   input integer n;
   begin
      case (n)
        0:       rw_reg = R_OUTPUT;
        1:       rw_reg = R_OE;
        2:       rw_reg = R_IRQ_EN;
        3:       rw_reg = R_IRQ_RISE;
        4:       rw_reg = R_IRQ_FALL;
        5:       rw_reg = R_IRQ_HIGH;
        6:       rw_reg = R_IRQ_LOW;
        7:       rw_reg = R_IN_EN;
        default: rw_reg = R_WAKE_EN;
      endcase
   end
endfunction

// Narrow write, expected-value update, full-word read back at every size
task narrow_wr;
   input [31:0] a;
   input [31:0] data;
   input  [1:0] size;
   reg   [31:0] lm;
   begin
      lm    = lane_mask(a, size);
      exp_v = ((exp_v & ~lm) | (lane_place(a, size, data) & lm)) & GPIO_MASK;
      apb_write(1, MACHINE, a, data, size, OK);
      apb_read(1, MACHINE, a & 32'hFFFFFFFC,       exp_v, SZ_W, 1'b1, OK);
      apb_read(1, MACHINE, (a & 32'hFFFFFFFC) + 0, exp_v, SZ_B, 1'b1, OK);
      apb_read(1, MACHINE, (a & 32'hFFFFFFFC) + 1, exp_v, SZ_B, 1'b1, OK);
      apb_read(1, MACHINE, (a & 32'hFFFFFFFC) + 2, exp_v, SZ_B, 1'b1, OK);
      apb_read(1, MACHINE, (a & 32'hFFFFFFFC) + 3, exp_v, SZ_B, 1'b1, OK);
      apb_read(1, MACHINE, (a & 32'hFFFFFFFC) + 0, exp_v, SZ_H, 1'b1, OK);
      apb_read(1, MACHINE, (a & 32'hFFFFFFFC) + 2, exp_v, SZ_H, 1'b1, OK);
   end
endtask

initial
   begin
      wait_reset_done(5);

      $display(" ===============================================");
      $display("|   BYTE / HALF-WORD WRITES TO RW REGISTERS     |");
      $display(" ===============================================");
      for (rr = 0; rr < 9; rr = rr + 1)
        begin
           addr  = rw_reg(rr);
           wr(addr, 32'h00000000);
           exp_v = 32'h0;
           for (ii = 0; ii < 4; ii = ii + 1)
             narrow_wr(addr + ii, $urandom | 32'h81, SZ_B);
           for (ii = 0; ii < 4; ii = ii + 1)
             narrow_wr(addr + ii, 32'h00, SZ_B);
           narrow_wr(addr,     32'hFFFF, SZ_H);
           narrow_wr(addr + 2, $urandom, SZ_H);
           narrow_wr(addr,     32'h0000, SZ_H);
           narrow_wr(addr + 2, 32'hFFFF, SZ_H);
           wr(addr, 32'hFFFFFFFF);
           exp_v = GPIO_MASK;
           for (ii = 0; ii < 4; ii = ii + 1)
             narrow_wr(addr + ii, 32'h00, SZ_B);
           wr(addr, 32'h00000000);
           if (addr == R_OUTPUT) chk32(gpio_o32,  32'h0, "gpio_o after byte-lane walk");
           if (addr == R_OE)     chk32(gpio_oe32, 32'h0, "gpio_oe_o after byte-lane walk");
        end

      $display(" ===============================================");
      $display("|   BYTE / HALF-WORD W1C ON IRQ_PEND            |");
      $display(" ===============================================");
      // Latch a rising edge on every pin, then clear lane by lane
      inputs_on(32'hFFFFFFFF);             // doc "Inputs": only enabled pins raise events
      wr(R_IRQ_RISE, 32'hFFFFFFFF);
      pins_set(32'hFFFFFFFF);
      cycles(L_IN + 3);
      wr(R_IRQ_RISE, 32'h00000000);
      exp_v = GPIO_MASK;
      rd(R_IRQ_PEND, exp_v);
      for (ii = 0; ii < 4; ii = ii + 1)
        begin
           apb_write(1, MACHINE, R_IRQ_PEND + ii, 32'hFF, SZ_B, OK);
           exp_v = exp_v & ~(32'hFF << (8*ii));
           rd(R_IRQ_PEND, exp_v);
        end

      pins_set(32'h00000000);
      wr(R_IRQ_RISE, 32'hFFFFFFFF);
      cycles(L_IN + 2);
      pins_set(32'hFFFFFFFF);
      cycles(L_IN + 3);
      wr(R_IRQ_RISE, 32'h00000000);
      exp_v = GPIO_MASK;
      rd(R_IRQ_PEND, exp_v);
      apb_write(1, MACHINE, R_IRQ_PEND + 2, 32'hFFFF, SZ_H, OK);
      exp_v = exp_v & 32'h0000FFFF;
      rd(R_IRQ_PEND, exp_v);
      apb_write(1, MACHINE, R_IRQ_PEND, 32'h00FF, SZ_H, OK);     // clears byte 0 only
      exp_v = exp_v & 32'h0000FF00;
      rd(R_IRQ_PEND, exp_v);
      apb_write(1, MACHINE, R_IRQ_PEND + 1, 32'hFF, SZ_B, OK);
      rd(R_IRQ_PEND, 32'h0);

      cycles(20);
      stimulus_done = 1;
   end
