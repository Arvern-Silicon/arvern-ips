//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    idle_bus
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : idle_bus.v
// Module Description : While PSEL is low the completer ignores the bus:
//                      random PENABLE, PWRITE, PADDR, PWDATA, PSTRB and
//                      PPROT values (every register offset, W1C and the
//                      set / clear / toggle aliases included) change no
//                      register, no output and no pending bit, PRDATA and
//                      PSLVERR stay 0 and pclk_en_o stays low; transfers
//                      before and after complete normally. The bench
//                      reference model runs alongside.
//
// AMBA APB: a completer acts only when selected (PSEL). Doc "Clocks":
// pclk_en_o requests pclk_i while the completer is selected.
//----------------------------------------------------------------------------

integer    ii;
integer    n0;
reg [31:0] out_v;

initial
   begin
      wait_reset_done(5);
      model_check_en = 1'b1;
      wr(R_OUTPUT, 32'h5A5A5A5A);
      wr(R_OE,     32'hFFFF0000);
      wr(R_IRQ_EN, 32'h0000FFFF);
      wr(R_IN_EN,  32'h0000000F);
      cycles(L_IN + 3);
      out_v = 32'h5A5A5A5A & GPIO_MASK;

      $display(" ===============================================");
      $display("|   RANDOM BUS VALUES WITH PSEL LOW             |");
      $display(" ===============================================");
      n0 = pclk_cnt;
      for (ii = 0; ii < 400; ii = ii + 1)
        begin
           psel    = 1'b0;
           penable = $urandom;
           pwrite  = $urandom;
           paddr   = ($urandom % 20) << 2;
           pwdata  = $urandom;
           pstrb   = $urandom;
           pprot   = $urandom;
           psmode  = $urandom;
           @(negedge free_clk);
           chk(prdata  === 32'h0, "PRDATA 0 while not selected");
           chk(pslverr === 1'b0, "PSLVERR 0 while not selected");
           chk(pclk_en === 1'b0, "pclk_en_o low while not selected");
           @(posedge free_clk); #1;
        end
      chk(pclk_cnt == n0, "no pclk edge while not selected");
      apb_idle;
      chk32(gpio_o32, out_v, "OUTPUT unchanged");
      chk32(gpio_oe32, 32'hFFFF0000 & GPIO_MASK, "OE unchanged");
      rd(R_OUTPUT, out_v);
      rd(R_IRQ_EN, 32'h0000FFFF & GPIO_MASK);
      rd(R_IN_EN,  32'h0000000F & GPIO_MASK);
      wr(R_OUT_TGL, 32'hFFFFFFFF);
      rd(R_OUTPUT, ~out_v & GPIO_MASK);

      cycles(2);
      stimulus_done = 1;
   end
