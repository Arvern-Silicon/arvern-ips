//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    out_set_clr_tgl
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : out_set_clr_tgl.v
// Module Description : OUT_SET / OUT_CLR / OUT_TGL: only the bits written 1
//                      change, every other OUTPUT bit (and OE) is untouched,
//                      the registers read 0, narrow writes act on their
//                      lanes only, and back-to-back operations compose.
//
// Doc "Register map": OUT_SET (0x14) "Writing 1 sets the OUTPUT bit; reads
// 0", OUT_CLR (0x18) "Writing 1 clears the OUTPUT bit; reads 0", OUT_TGL
// (0x1C) "Writing 1 inverts the OUTPUT bit; reads 0"; "change individual pins
// without a read-modify-write"; "Byte and half-word writes update only the
// addressed byte lanes; reads always return the whole word".
// The BFM fills unaddressed lanes with random junk, so a lane leak shows.
//----------------------------------------------------------------------------

integer    ii;
integer    jj;
reg [31:0] exp_out;
reg [31:0] oe_val;
reg [31:0] val;
reg [31:0] saved;

// One set/clear/toggle operation, pins checked across the ACCESS cycle
task out_op;
   input [31:0] addr;
   input [31:0] data;          // value in the low bits, as for apb_write
   input  [1:0] size;
   reg   [31:0] eff;
   reg   [31:0] v_before;
   begin
      eff    = lane_place(addr, size, data) & lane_mask(addr, size) & GPIO_MASK;
      v_before = exp_out;
      case (addr & 32'hFFFFFFFC)
        R_OUT_SET: exp_out = exp_out |  eff;
        R_OUT_CLR: exp_out = exp_out & ~eff;
        default  : exp_out = exp_out ^  eff;
      endcase
      apb_write(0, MACHINE, addr, data, size, OK);
      @(negedge free_clk);
      chk32(gpio_o32, v_before, "gpio_o unchanged during the set/clr/tgl ACCESS cycle");
      @(posedge free_clk);
      #1;
      chk32(gpio_o32, exp_out, "gpio_o after set/clr/tgl");
      rd(R_OUTPUT, exp_out);
      apb_read(1, MACHINE, addr & 32'hFFFFFFFC, 32'h0, SZ_W, 1'b1, OK);
      chk32(gpio_oe32, oe_val, "OE untouched by set/clr/tgl");
   end
endtask

initial
   begin
      wait_reset_done(5);

      oe_val = $urandom & GPIO_MASK;
      wr(R_OE, oe_val);
      exp_out = 32'h0;

      $display(" ===============================================");
      $display("|   WORD SET / CLR / TGL                        |");
      $display(" ===============================================");
      out_op(R_OUT_SET, 32'h00000001, SZ_W);
      out_op(R_OUT_SET, 32'h80000000, SZ_W);
      out_op(R_OUT_SET, 32'hFFFFFFFF, SZ_W);
      out_op(R_OUT_CLR, 32'h00000000, SZ_W);
      out_op(R_OUT_CLR, 32'h0000FF00, SZ_W);
      out_op(R_OUT_CLR, 32'hFFFFFFFF, SZ_W);
      out_op(R_OUT_TGL, 32'hA5A5A5A5, SZ_W);
      out_op(R_OUT_TGL, 32'hFFFFFFFF, SZ_W);
      out_op(R_OUT_TGL, 32'h00000000, SZ_W);
      for (ii = 0; ii < 24; ii = ii + 1)
        begin
           val = $urandom;
           case (ii % 3)
             0: out_op(R_OUT_SET, val, SZ_W);
             1: out_op(R_OUT_CLR, val, SZ_W);
             default: out_op(R_OUT_TGL, val, SZ_W);
           endcase
        end

      $display(" ===============================================");
      $display("|   BYTE / HALF-WORD SET / CLR / TGL            |");
      $display(" ===============================================");
      for (jj = 0; jj < 3; jj = jj + 1)
        begin
           for (ii = 0; ii < 4; ii = ii + 1)
             begin
                wr(R_OUTPUT, 32'h5A5A5A5A);
                exp_out = 32'h5A5A5A5A & GPIO_MASK;
                out_op(R_OUT_SET + jj*4 + ii, 32'hFF, SZ_B);
                out_op(R_OUT_SET + jj*4 + ii, $urandom, SZ_B);
             end
           for (ii = 0; ii < 4; ii = ii + 2)
             begin
                wr(R_OUTPUT, 32'hA5A5A5A5);
                exp_out = 32'hA5A5A5A5 & GPIO_MASK;
                out_op(R_OUT_SET + jj*4 + ii, 32'hFFFF, SZ_H);
                out_op(R_OUT_SET + jj*4 + ii, $urandom, SZ_H);
             end
        end

      $display(" ===============================================");
      $display("|   NARROW READS OF THE WRITE-ONLY REGISTERS    |");
      $display(" ===============================================");
      wr(R_OUTPUT, 32'hFFFFFFFF);
      exp_out = GPIO_MASK;
      for (jj = 0; jj < 3; jj = jj + 1)
        begin
           for (ii = 0; ii < 4; ii = ii + 1)
             apb_read(1, MACHINE, R_OUT_SET + jj*4 + ii, 32'h0, SZ_B, 1'b1, OK);
           apb_read(1, MACHINE, R_OUT_SET + jj*4,     32'h0, SZ_H, 1'b1, OK);
           apb_read(1, MACHINE, R_OUT_SET + jj*4 + 2, 32'h0, SZ_H, 1'b1, OK);
        end

      $display(" ===============================================");
      $display("|   BACK-TO-BACK OPERATIONS                     |");
      $display(" ===============================================");
      for (ii = 0; ii < 8; ii = ii + 1)
        begin
           saved = $urandom & GPIO_MASK;
           val   = $urandom;
           wr(R_OUTPUT, saved);
           // SET, CLR, TGL, TGL back to back: each SETUP in the cycle after the previous ACCESS
           apb_write(0, MACHINE, R_OUT_SET, val, SZ_W, OK);
           apb_write(0, MACHINE, R_OUT_CLR, val, SZ_W, OK);
           #0;
           chk32(gpio_o32, (saved | val) & GPIO_MASK, "back-to-back: after OUT_SET");
           apb_write(0, MACHINE, R_OUT_TGL, ~val, SZ_W, OK);
           chk32(gpio_o32, (saved & ~val) & GPIO_MASK, "back-to-back: after OUT_CLR");
           apb_write(0, MACHINE, R_OUT_TGL, ~val, SZ_W, OK);
           chk32(gpio_o32, ((saved & ~val) ^ ~val) & GPIO_MASK, "back-to-back: after first OUT_TGL");
           apb_read(0, MACHINE, R_OUTPUT, (saved & ~val) & GPIO_MASK, SZ_W, 1'b1, OK);
           chk32(gpio_o32, (saved & ~val) & GPIO_MASK, "back-to-back: after second OUT_TGL");
           apb_flush;
           chk32(gpio_oe32, oe_val, "OE untouched by back-to-back set/clr/tgl");
        end

      cycles(20);
      stimulus_done = 1;
   end
