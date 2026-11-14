//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    pslverr_timing
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : pslverr_timing.v
// Module Description : Cycle-exact PSLVERR with MDELEG set to Machine mode
//                      only and RESP=1 (written first, whatever MDELEG_RST),
//                      driven by hand rather than by the
//                      BFM: PSLVERR is low in SETUP, high in the ACCESS
//                      cycle of a denied transfer and low again after it;
//                      a denied read returns 0; two denied transfers back
//                      to back raise PSLVERR in each ACCESS and not in the
//                      SETUP between them; an admitted write right after a
//                      denied one takes effect; a denied W1C clears nothing;
//                      pclk_en_o stays high through every transfer.
//
// Doc "Access protection": with RESP=1 a refused access is answered with
// PSLVERR in its ACCESS cycle; a refused write changes nothing and a refused
// read returns 0. Doc "Clocks": pclk_en_o requests pclk_i while the completer
// is selected.
//----------------------------------------------------------------------------

reg [31:0] out0;

// One SETUP + ACCESS by hand, back to back with the previous one when
// called right after it; checks PSLVERR and PRDATA in both cycles
task xfer;
   input  [1:0] mode;
   input [31:0] addr;
   input        write;
   input [31:0] data;
   input        exp_err;
   begin
      psel    = 1'b1;
      penable = 1'b0;
      paddr   = addr[ADDRW-1:0];
      pwrite  = write;
      pwdata  = data;
      pstrb   = write ? 4'hF : 4'h0;
      pprot   = {2'b00, mode[1]};
      psmode  = mode[0];
      @(negedge free_clk);
      chk(pslverr === 1'b0, "PSLVERR low in SETUP");
      chk(prdata  === 32'h0, "PRDATA 0 in SETUP");
      chk(pclk_en === 1'b1, "pclk_en_o high in SETUP");
      @(posedge free_clk); #1;
      penable = 1'b1;
      @(negedge free_clk);
      chk(pslverr === exp_err, "PSLVERR in ACCESS as expected");
      if (!write && exp_err) chk(prdata === 32'h0, "denied read returns 0");
      chk(pclk_en === 1'b1, "pclk_en_o high in ACCESS");
      @(posedge free_clk); #1;
   end
endtask

task release_bus;
   begin
      apb_idle;
      @(negedge free_clk);
      chk(pslverr === 1'b0, "PSLVERR low after the transfer");
      @(posedge free_clk); #1;
   end
endtask

initial
   begin
      wait_reset_done(5);
      wr(R_MDELEG, 32'h0000010F);

      out0 = 32'h00C0FFEE & GPIO_MASK;
      wr(R_OUTPUT, out0);
      wr(R_OE,     32'h0);
      @(posedge free_clk); #1;

      $display(" ===============================================");
      $display("|   DENIED WRITE, DENIED READ                   |");
      $display(" ===============================================");
      xfer(USER,       R_OUTPUT, 1'b1, 32'hFFFFFFFF, 1'b1);
      release_bus;
      chk32(gpio_o32, out0, "denied write changed nothing");
      xfer(SUPERVISOR, R_OUTPUT, 1'b0, 32'h0, 1'b1);
      release_bus;

      $display(" ===============================================");
      $display("|   TWO DENIED TRANSFERS BACK TO BACK           |");
      $display(" ===============================================");
      xfer(USER_S,     R_OUT_TGL, 1'b1, 32'hFFFFFFFF, 1'b1);
      xfer(SUPERVISOR, R_INFO,    1'b0, 32'h0,        1'b1);
      release_bus;
      chk32(gpio_o32, out0, "denied toggle changed nothing");

      $display(" ===============================================");
      $display("|   ADMITTED WRITE RIGHT AFTER A DENIED ONE     |");
      $display(" ===============================================");
      xfer(USER,    R_OUT_SET, 1'b1, 32'hFFFFFFFF, 1'b1);
      xfer(MACHINE, R_OUT_TGL, 1'b1, 32'h00000003, 1'b0);
      release_bus;
      chk32(gpio_o32, (out0 ^ 32'h3) & GPIO_MASK, "admitted toggle took effect");
      xfer(MACHINE, R_OUTPUT,  1'b0, 32'h0, 1'b0);
      release_bus;

      $display(" ===============================================");
      $display("|   DENIED W1C OF IRQ_PEND                      |");
      $display(" ===============================================");
      wr(R_IRQ_HIGH, 32'h1);
      wr(R_IN_EN,    32'h1);
      pins_set(32'h1);
      cycles(L_IN + 3);
      wr(R_IRQ_HIGH, 32'h0);
      wr(R_IRQ_RISE, 32'h1);
      pins_set(32'h0);
      cycles(L_IN + 2);
      pins_set(32'h1);
      cycles(L_IN + 3);
      rd(R_IRQ_PEND, 32'h1);
      @(posedge free_clk); #1;
      xfer(USER, R_IRQ_PEND, 1'b1, 32'hFFFFFFFF, 1'b1);
      release_bus;
      rd(R_IRQ_PEND, 32'h1);
      wr(R_IRQ_PEND, 32'h1);
      rd(R_IRQ_PEND, 32'h0);

      cycles(2);
      stimulus_done = 1;
   end
