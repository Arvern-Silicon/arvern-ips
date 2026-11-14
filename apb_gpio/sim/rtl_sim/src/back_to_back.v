//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    back_to_back
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : back_to_back.v
// Module Description : Back-to-back transfers (each SETUP in the cycle after
//                      the previous ACCESS): write -> read of the same
//                      register returns the new value (OUTPUT, OE, IRQ_EN,
//                      mode registers, narrow writes), set/clr/tgl -> read
//                      OUTPUT, W1C -> read IRQ_PEND, read -> write -> read;
//                      then a long random stream checked against the bench
//                      reference model.
//
// Doc "Register map" / "Interrupts": a write "takes effect at the end of its
// ACCESS cycle", so the next transfer, back to back, sees it.
// The stream uses the reference model (gpio_model.v), pins static.
//----------------------------------------------------------------------------

`define LONG_TIMEOUT

integer    ii;
integer    op;
reg [31:0] v;
reg [31:0] w;
reg [31:0] shadow_out;
reg [31:0] a;
reg  [1:0] sz;

function [31:0] rw_addr;
   input integer n;
   begin
      case (n % 9)
        0:       rw_addr = R_OUTPUT;
        1:       rw_addr = R_OE;
        2:       rw_addr = R_IRQ_EN;
        3:       rw_addr = R_IRQ_RISE;
        4:       rw_addr = R_IRQ_FALL;
        5:       rw_addr = R_IRQ_HIGH;
        6:       rw_addr = R_IRQ_LOW;
        7:       rw_addr = R_IN_EN;
        default: rw_addr = R_WAKE_EN;
      endcase
   end
endfunction

initial
   begin
      wait_reset_done(5);

      $display(" ===============================================");
      $display("|   WRITE -> READ, SAME REGISTER                |");
      $display(" ===============================================");
      for (ii = 0; ii < 36; ii = ii + 1)
        begin
           a = rw_addr(ii);
           v = $urandom;
           w = $urandom;
           apb_write(0, MACHINE, a, v, SZ_W, OK);
           apb_read (0, MACHINE, a, v & GPIO_MASK, SZ_W, 1'b1, OK);
           apb_write(0, MACHINE, a, w, SZ_W, OK);
           apb_read (0, MACHINE, a, w & GPIO_MASK, SZ_W, 1'b1, OK);
           apb_write(0, MACHINE, a + 1, v, SZ_B, OK);
           apb_read (0, MACHINE, a, ((w & 32'hFFFF00FF) | ((v & 32'hFF) << 8)) & GPIO_MASK, SZ_B, 1'b1, OK);
           apb_write(0, MACHINE, a + 2, v, SZ_H, OK);
           apb_read (1, MACHINE, a, ((w & 32'h000000FF) | ((v & 32'hFF) << 8) | ((v & 32'hFFFF) << 16)) & GPIO_MASK, SZ_W, 1'b1, OK);
        end
      wr(R_IRQ_RISE, 32'h0);
      wr(R_IRQ_FALL, 32'h0);
      wr(R_IRQ_HIGH, 32'h0);
      wr(R_IRQ_LOW,  32'h0);
      wr(R_WAKE_EN,  32'h0);

      $display(" ===============================================");
      $display("|   SET / CLR / TGL -> READ OUTPUT              |");
      $display(" ===============================================");
      shadow_out = 32'h0;
      wr(R_OUTPUT, shadow_out);
      for (ii = 0; ii < 24; ii = ii + 1)
        begin
           v = $urandom;
           op = ii % 3;
           if (op == 0) begin apb_write(0, MACHINE, R_OUT_SET, v, SZ_W, OK); shadow_out = (shadow_out |  v) & GPIO_MASK; end
           if (op == 1) begin apb_write(0, MACHINE, R_OUT_CLR, v, SZ_W, OK); shadow_out = (shadow_out & ~v) & GPIO_MASK; end
           if (op == 2) begin apb_write(0, MACHINE, R_OUT_TGL, v, SZ_W, OK); shadow_out = (shadow_out ^  v) & GPIO_MASK; end
           apb_read(0, MACHINE, R_OUTPUT, shadow_out, SZ_W, 1'b1, OK);
        end
      apb_flush;
      chk32(gpio_o32, shadow_out, "gpio_o after a back-to-back set/clr/tgl stream");

      $display(" ===============================================");
      $display("|   W1C -> READ IRQ_PEND, READ -> WRITE -> READ |");
      $display(" ===============================================");
      inputs_on(32'hFFFFFFFF);
      wr(R_IRQ_RISE, 32'hFFFFFFFF);
      pins_set(32'hFFFFFFFF);
      cycles(L_IN + 3);
      wr(R_IRQ_RISE, 32'h0);
      v = GPIO_MASK;
      apb_read (0, MACHINE, R_IRQ_PEND, v, SZ_W, 1'b1, OK);
      for (ii = 0; ii < 8; ii = ii + 1)
        begin
           w = 32'hF << (4*ii);
           apb_write(0, MACHINE, R_IRQ_PEND, w, SZ_W, OK);
           v = v & ~w;
           apb_read (0, MACHINE, R_IRQ_PEND, v, SZ_W, 1'b1, OK);
        end
      wr(R_OE, 32'h0);                         // the earlier sections leave OE random
      apb_read (0, MACHINE, R_OE, 32'h0, SZ_W, 1'b1, OK);
      apb_write(0, MACHINE, R_OE, 32'hC0DEC0DE, SZ_W, OK);
      apb_read (0, MACHINE, R_OE, 32'hC0DEC0DE & GPIO_MASK, SZ_W, 1'b1, OK);
      apb_read (0, MACHINE, R_INFO, INFO_VALUE, SZ_W, 1'b1, OK);
      apb_write(0, MACHINE, R_OE, 32'h0, SZ_W, OK);
      apb_read (1, MACHINE, R_OE, 32'h0, SZ_W, 1'b1, OK);

      $display(" ===============================================");
      $display("|   RANDOM BACK-TO-BACK STREAM VS. THE MODEL    |");
      $display(" ===============================================");
      cycles(L_IN + 3);
      model_check_en = 1'b1;
      for (ii = 0; ii < 400; ii = ii + 1)
        begin
           op = $urandom % 16;
           v  = $urandom;
           a  = reg_addr($urandom % (REG_NR + 1));          // every register and one unmapped word
           sz = v[29:28] % 3;
           a  = a + ((sz == SZ_B) ? v[25:24] : (sz == SZ_H) ? {v[25], 1'b0} : 2'b00);
           if (op < 8)
             apb_write(0, MACHINE, a, v, sz, OK);
           else
             apb_read (0, MACHINE, a, 32'h0, sz, 1'b0, OK);    // checked by the model
           if (op == 15) cycles($urandom % 3);
        end
      apb_flush;
      cycles(5);
      model_check_en = 1'b0;
      $display("model mismatches in the stream: %0d", m_errors);

      cycles(20);
      stimulus_done = 1;
   end
