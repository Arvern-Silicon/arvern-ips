//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mdeleg_reset
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mdeleg_reset.v
// Module Description : MDELEG comes out of reset at MDELEG_RST, and the gates it
//                      holds apply from the first transfer: every mode writes and
//                      reads a REGOUT register, reads a REGIN register and reads
//                      MDELEG before any MDELEG write. MDELEG is then rewritten,
//                      and a reset restores it. Run on the default build and on
//                      the open one (-D MDELEG_RST=1).
//----------------------------------------------------------------------------
localparam REGOUT_00 = 32'h00400000;
localparam REGIN_08  = 32'h00400020;
localparam MDELEG    = 32'h00400040;

localparam [31:0] MDELEG_RST_WORD = {23'h0, MDELEG_RST};

integer   m;
reg [1:0] mode;
reg       wr_ok, rd_ok, resp;
reg [1:0] new_wr, new_rd;

task sweep;
   begin
      resp = MDELEG_RST[8];
      ahb_read (1, MACHINE, MDELEG, MDELEG_RST_WORD, 2, 1, OK);
      for (m = 0; m < 3; m = m + 1) begin
         mode  = (m == 0) ? USER : (m == 1) ? SUPERVISOR : MACHINE;
         wr_ok = (mode >= MDELEG_RST[1:0]);
         rd_ok = (mode >= MDELEG_RST[3:2]);
         ahb_write(1, mode,    REGOUT_00 + 4*m, 32'hC0DE_0000 + m, 2, ~wr_ok & resp);
         ahb_read (1, MACHINE, REGOUT_00 + 4*m, wr_ok ? 32'hC0DE_0000 + m : 32'h0, 2, 1, OK);
         ahb_read (1, mode,    REGOUT_00 + 4*m, (wr_ok & rd_ok) ? 32'hC0DE_0000 + m : 32'h0, 2, 1, ~rd_ok & resp);
         ahb_read (1, mode,    REGIN_08  + 4*m, rd_ok ? 32'h1111_1111 * (m + 1) : 32'h0, 2, 1, ~rd_ok & resp);
         ahb_read (1, mode,    MDELEG, (mode == MACHINE) ? MDELEG_RST_WORD : 32'h0, 2, 1, (mode != MACHINE) & resp);
      end
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk); #1;
      periph0_reg_08_in = 32'h1111_1111;
      periph0_reg_09_in = 32'h2222_2222;
      periph0_reg_10_in = 32'h3333_3333;

      $display("");
      $display(" MDELEG_RST = 9'h%03h", MDELEG_RST);
      sweep;

      // Rewrite MDELEG to a value that differs from the reset one in every field
      new_wr = (MDELEG_RST[1:0] == 2'b11) ? 2'b00 : 2'b11;
      new_rd = (MDELEG_RST[3:2] == 2'b11) ? 2'b00 : 2'b11;
      ahb_write(1, MACHINE, MDELEG, {23'h0, ~MDELEG_RST[8], 4'h0, new_rd, new_wr}, 2, OK);
      ahb_read (1, MACHINE, MDELEG, {23'h0, ~MDELEG_RST[8], 4'h0, new_rd, new_wr}, 2, 1, OK);

      // Reset between transfers restores MDELEG_RST and clears the registers
      @(posedge free_clk); #1;
      hresetn = 1'b0;
      repeat(3) @(posedge free_clk); #1;
      hresetn = 1'b1;
      repeat(2) @(posedge free_clk); #1;
      sweep;

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
