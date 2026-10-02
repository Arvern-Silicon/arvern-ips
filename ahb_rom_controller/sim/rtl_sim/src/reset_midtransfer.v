//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    reset_midtransfer
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : reset_midtransfer.v
// Module Description : Reset asserted mid-transfer, in either reset style: in the
//                      first cycle of a write ERROR and in a read data phase.
//                      During reset hreadyout is high and hresp low (at once with
//                      an asynchronous reset; by the first clock edge with a
//                      synchronous one, since the clock runs during reset), no ROM command is issued, and the bus is idle
//                      and usable again after reset.
//----------------------------------------------------------------------------

localparam ROM_W0 = 32'h00400000;
localparam ROM_W1 = 32'h00400004;

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

task bus_idle;
   begin
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hwrite = 1'b0;
      hsize  = 3'b010;
   end
endtask

task preload;
   begin
      rom_inst.mem[0] = 32'hC0DE0000;
      rom_inst.mem[1] = 32'hC0DE0001;
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      preload;
      repeat(5) @(posedge free_clk); #1;

      // Reset in ERROR cycle 1.
      haddr = ROM_W0; htrans = 2'b10; hwrite = 1'b1; hsize = 3'b010;
      @(posedge free_clk); #1;
      bus_idle;
      chk(hreadyout === 1'b0 && hresp === 1'b1, "setup: ERROR cycle 1 not reached");
      hresetn = 1'b0;
      if (ASYNC_RST_EN) begin
         #1;
         chk(hreadyout === 1'b1 && hresp === 1'b0, "async reset: ERROR not cleared before the next edge");
      end
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b0 && rom_cen === 1'b1, "in reset: hreadyout 1, hresp 0, no ROM command");
      repeat(3) @(posedge free_clk); #1;
      hresetn = 1'b1;
      repeat(2) @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b0 && hrdata === 32'h0, "after reset: bus not idle");

      // Reset in a read data phase.
      haddr = ROM_W1; htrans = 2'b10; hwrite = 1'b0;
      @(posedge free_clk); #1;
      bus_idle;
      hresetn = 1'b0;
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b0 && hrdata === 32'h0, "in reset: read data not cleared");
      repeat(3) @(posedge free_clk); #1;
      hresetn = 1'b1;
      repeat(2) @(posedge free_clk); #1;

      // Usable again.
      ahb_read(1, ROM_W1, 32'hC0DE0001, 2, 1);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
