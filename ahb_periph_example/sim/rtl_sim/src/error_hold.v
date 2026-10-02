//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    error_hold
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : error_hold.v
// Module Description : The next transfer held through a two-cycle ERROR response.
//                      The master presents its next address phase while the ERROR
//                      is in progress and keeps it: it is not taken in the first
//                      ERROR cycle (hready low), is taken in the second, and then
//                      completes normally. Two denied transfers back to back give
//                      two complete ERROR responses.
//----------------------------------------------------------------------------

localparam REGOUT_00 = 32'h00400000;
localparam REGOUT_01 = 32'h00400004;

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

      ahb_write(1, MACHINE, REGOUT_00, 32'h00000000, 2, OK);
      ahb_write(1, MACHINE, REGOUT_01, 32'hC0FFEE01, 2, OK);
      @(posedge free_clk); #1;

      // Denied User write, then a Machine read held through the ERROR.
      haddr = REGOUT_00; htrans = 2'b10; hwrite = 1'b1; hsize = 3'b010; set_mode(USER);
      @(posedge free_clk); #1;
      hwdata = 32'hDEADBEEF;
      haddr = REGOUT_01; htrans = 2'b10; hwrite = 1'b0; set_mode(MACHINE);
      chk(hreadyout === 1'b0 && hresp === 1'b1, "ERROR cycle 1: expected hreadyout=0, hresp=1");
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b1, "ERROR cycle 2: expected hreadyout=1, hresp=1");
      @(posedge free_clk); #1;                           // held read taken at this edge
      bus_idle;
      chk(hreadyout === 1'b1 && hresp === 1'b0, "held read after ERROR: data phase not OKAY");
      chk(hrdata === 32'hC0FFEE01, "held read after ERROR returned the wrong data");
      @(posedge free_clk); #1;
      chk(periph0_reg_00_out === 32'h00000000, "denied write reached the register");

      // Two denied transfers back to back.
      haddr = REGOUT_00; htrans = 2'b10; hwrite = 1'b1; hsize = 3'b010; set_mode(USER);
      @(posedge free_clk); #1;
      hwdata = 32'h11111111;
      haddr = REGOUT_01; htrans = 2'b10; hwrite = 1'b0; set_mode(USER);
      chk(hreadyout === 1'b0 && hresp === 1'b1, "1st ERROR cycle 1");
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b1, "1st ERROR cycle 2");
      @(posedge free_clk); #1;                           // second denied transfer taken
      bus_idle;
      chk(hreadyout === 1'b0 && hresp === 1'b1, "2nd ERROR cycle 1");
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b1, "2nd ERROR cycle 2");
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b0, "bus not back to OKAY after the second ERROR");
      chk(periph0_reg_00_out === 32'h00000000, "second denied sequence wrote the register");

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
