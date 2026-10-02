//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    error_pipelined
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : error_pipelined.v
// Module Description : Write ERRORs in pipelined traffic, the manager holding its
//                      next address phase through the first ERROR cycle: two writes
//                      back to back, a read followed by a write, and a write followed
//                      by a read. The bus monitor checks both ERROR cycles of every
//                      write; the reads are checked for data.
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

      // Write -> write, second address phase held through ERROR cycle 1.
      haddr = ROM_W0; htrans = 2'b10; hwrite = 1'b1; hsize = 3'b010;
      @(posedge free_clk); #1;                        // write 1 taken
      hwdata = 32'h11111111;
      haddr = ROM_W1; hwrite = 1'b1;                  // write 2 presented
      @(posedge free_clk); #1;                        // ERROR 1, not taken
      @(posedge free_clk); #1;                        // ERROR 2, write 2 taken
      bus_idle;
      hwdata = 32'h22222222;
      @(posedge free_clk); #1;                        // write 2 ERROR 1
      @(posedge free_clk); #1;                        // write 2 ERROR 2
      @(posedge free_clk); #1;

      // Read -> write.
      haddr = ROM_W0; htrans = 2'b10; hwrite = 1'b0;
      @(posedge free_clk); #1;                        // read taken
      haddr = ROM_W1; hwrite = 1'b1;
      chk(hrdata === 32'hC0DE0000, "read before a write returned the wrong word");
      @(posedge free_clk); #1;                        // write taken
      bus_idle;
      hwdata = 32'h33333333;
      repeat(3) @(posedge free_clk); #1;

      // Write -> read, read held through ERROR cycle 1.
      haddr = ROM_W0; htrans = 2'b10; hwrite = 1'b1;
      @(posedge free_clk); #1;                        // write taken
      hwdata = 32'h44444444;
      haddr = ROM_W1; hwrite = 1'b0;                  // read presented
      @(posedge free_clk); #1;                        // ERROR 1
      @(posedge free_clk); #1;                        // ERROR 2, read taken
      bus_idle;
      chk(hrdata === 32'hC0DE0001, "read after a write ERROR returned the wrong word");
      @(posedge free_clk); #1;

      chk(rom_inst.mem[0] === 32'hC0DE0000 && rom_inst.mem[1] === 32'hC0DE0001, "a write reached the ROM");

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
