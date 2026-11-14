//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    input_readback
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : input_readback.v
// Module Description : INPUT samples gpio_i whatever OE: with a pad model a
//                      driven pin reads back its own output, an undriven pin
//                      the external value; without the pad loop INPUT follows
//                      gpio_i, not OUTPUT. An edge interrupt fires from the
//                      IP's own output toggled through the pad.
//
// Doc "Inputs": "Pins are sampled whatever their OE, so a driven pin reads
// back its own output (through the pad)." Doc "Register map": INPUT = "Pin
// values after the input stage".
//----------------------------------------------------------------------------

integer    ii;
reg [31:0] ext_v;
reg [31:0] out_v;
reg [31:0] oe_v;
integer    p;

initial
   begin
      wait_reset_done(5);
      inputs_on(32'hFFFFFFFF);  // doc "Inputs": a pin is sampled only while IN_EN=1

      $display(" ===============================================");
      $display("|   NO PAD LOOP: INPUT IS gpio_i, NOT OUTPUT    |");
      $display(" ===============================================");
      tb_pad_loop = 1'b0;
      wr(R_OE,     32'hFFFFFFFF);
      wr(R_OUTPUT, 32'hA5A5A5A5);
      pins_set(32'h5A5A5A5A);
      cycles(L_IN + 1);
      rd(R_INPUT, 32'h5A5A5A5A & GPIO_MASK);
      wr(R_OE, 32'h0);
      cycles(L_IN + 1);
      rd(R_INPUT, 32'h5A5A5A5A & GPIO_MASK);

      $display(" ===============================================");
      $display("|   PAD LOOP: DRIVEN PINS READ BACK gpio_o      |");
      $display(" ===============================================");
      tb_pad_loop = 1'b1;
      for (ii = 0; ii < 12; ii = ii + 1)
        begin
           ext_v = $urandom;
           out_v = $urandom;
           oe_v  = (ii == 0) ? 32'hFFFFFFFF : (ii == 1) ? 32'h0 : $urandom;
           wr(R_OUTPUT, out_v);
           wr(R_OE,     oe_v);
           pins_set(ext_v);
           cycles(L_IN + 1);
           rd(R_INPUT, ((oe_v & out_v) | (~oe_v & ext_v)) & GPIO_MASK);
        end

      $display(" ===============================================");
      $display("|   EDGE INTERRUPT FROM THE OWN OUTPUT          |");
      $display(" ===============================================");
      p = pick_pin(3);
      wr(R_OUTPUT, 32'h0);
      wr(R_OE,     pbit(p));
      pins_set(32'h0);
      wr(R_IRQ_RISE, pbit(p));
      wr(R_IRQ_EN,   pbit(p));
      cycles(L_IN + 3);
      rd(R_IRQ_PEND, 32'h0);
      wr(R_OUT_TGL, pbit(p));                   // drives the pin high through the pad
      cycles(L_IN + 2);
      rd(R_INPUT, pbit(p));
      rd(R_IRQ_PEND, pbit(p));
      chk((irq32 & pbit(p)) != 0, "irq_o from a rising edge of the IP's own output");
      wr(R_IRQ_PEND, pbit(p));
      rd(R_IRQ_PEND, 32'h0);
      tb_pad_loop = 1'b0;

      cycles(20);
      stimulus_done = 1;
   end
