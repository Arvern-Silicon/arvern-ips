//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    reset_mid_transfer
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : reset_mid_transfer.v
// Module Description : Reset asserted in the middle of a transfer, in either reset
//                      style. hreadyout_o is high during reset (by the first clock
//                      edge in a synchronous-reset build; the clock runs during
//                      reset), hresp_o is low, a data phase cut by reset commits
//                      nothing, and every register comes out at its reset value.
//----------------------------------------------------------------------------

localparam REGOUT_00 = 32'h00400000;
localparam REGOUT_01 = 32'h00400004;
localparam MDELEG    = 32'h00400040;

task chk;
   input        cond;
   input [8*72-1:0] msg;
   begin
      if (cond !== 1'b1) begin
         $display("ERROR: %0s %t ns", msg, $time);
         error = error + 1;
      end
   end
endtask

// Bus back to idle, sampled on the next edge.
task bus_idle;
   begin
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hwrite = 1'b0;
      hsize  = 3'b000;
      set_mode(USER);
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk); #1;

      ahb_write(1, MACHINE, REGOUT_00, 32'hA5A5A5A5, 2, OK);
      @(posedge free_clk); #1;

      // 1. Reset in the first ERROR cycle of a denied write.
      haddr = REGOUT_00; htrans = 2'b10; hwrite = 1'b1; hsize = 3'b010; set_mode(USER);
      @(posedge free_clk); #1;
      bus_idle;
      chk(hreadyout === 1'b0 && hresp === 1'b1, "setup: ERROR cycle 1 not reached");
      hresetn = 1'b0;
      if (ASYNC_RST_EN) begin
         #1;
         chk(hreadyout === 1'b1 && hresp === 1'b0, "async reset: hreadyout/hresp not released at once");
      end
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b0, "in reset: hreadyout must be 1 and hresp 0");
      repeat(3) @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b0, "in reset: hreadyout/hresp not held");
      hresetn = 1'b1;
      repeat(2) @(posedge free_clk); #1;
      chk(periph0_reg_00_out === 32'h00000000, "REGOUT_00 not at its reset value");

      // 2. Reset in the data phase of an admitted write.
      ahb_read (1, MACHINE, MDELEG, 32'h0000010F, 2, 1, OK);
      haddr = REGOUT_01; htrans = 2'b10; hwrite = 1'b1; hsize = 3'b010; set_mode(MACHINE);
      @(posedge free_clk); #1;                           // address phase taken
      bus_idle;
      hwdata = 32'h5A5A5A5A;
      hresetn = 1'b0;                                    // before the committing edge
      repeat(4) @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b0, "in reset: hreadyout/hresp not idle");
      hresetn = 1'b1;
      repeat(2) @(posedge free_clk); #1;
      chk(periph0_reg_01_out === 32'h00000000, "data phase cut by reset committed its write");
      ahb_read (1, MACHINE, MDELEG, 32'h0000010F, 2, 1, OK);
      ahb_read (1, USER,    REGOUT_01, 32'h00000000, 2, 0, ERROR);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
