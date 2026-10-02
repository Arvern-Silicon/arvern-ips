//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    hready_stall
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : hready_stall.v
// Module Description : Another subordinate stalls the shared bus: hready is low
//                      while a ROM address phase is presented. It is not taken (no
//                      ROM command, clock enable low); withdrawn, nothing happens and
//                      no ERROR is raised for a withdrawn write; held, it is taken
//                      exactly once when the stall ends. The bus monitor checks every
//                      data phase.
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
integer cyc;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      preload;
      repeat(5) @(posedge free_clk); #1;

      // Read presented during the stall, then withdrawn.
      tb_hready_stall = 1'b1;
      haddr = ROM_W1; htrans = 2'b10; hwrite = 1'b0; hsize = 3'b010;
      for (cyc = 0; cyc < 3; cyc = cyc + 1) begin
         chk(rom_cen === 1'b1, "stalled read: ROM command issued");
         chk(hclk_en === 1'b0, "stalled read: clock enable high");
         @(posedge free_clk); #1;
      end
      bus_idle;
      @(posedge free_clk); #1;
      tb_hready_stall = 1'b0;
      repeat(2) @(posedge free_clk); #1;

      // Write presented during the stall, then withdrawn: no ERROR afterwards.
      tb_hready_stall = 1'b1;
      haddr = ROM_W0; htrans = 2'b10; hwrite = 1'b1; hsize = 3'b010;
      repeat(3) @(posedge free_clk); #1;
      bus_idle;
      @(posedge free_clk); #1;
      tb_hready_stall = 1'b0;
      repeat(3) @(posedge free_clk); #1;
      chk(hresp === 1'b0, "withdrawn write raised an ERROR");

      // Read held through the stall: taken once, data one cycle later.
      tb_hready_stall = 1'b1;
      haddr = ROM_W1; htrans = 2'b10; hwrite = 1'b0; hsize = 3'b010;
      repeat(3) @(posedge free_clk); #1;
      chk(rom_cen === 1'b1, "held read: ROM command issued during the stall");
      tb_hready_stall = 1'b0;
      #2;                                     // past the bench's 1 ns input delay
      chk(rom_cen === 1'b0, "held read: no ROM command once the stall ends");
      @(posedge free_clk); #1;                        // address phase taken
      bus_idle;
      chk(hrdata === 32'hC0DE0001, "held read returned the wrong word");
      @(posedge free_clk); #1;

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
