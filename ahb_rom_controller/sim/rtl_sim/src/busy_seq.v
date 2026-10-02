//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    busy_seq
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : busy_seq.v
// Module Description : SEQ and BUSY beats. A NONSEQ read followed by a SEQ read is
//                      two transfers; a BUSY beat between them is not a transfer: no
//                      ROM command, zero-wait OKAY. The bus monitor checks every
//                      data phase; the two reads are checked for data.
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

      haddr = ROM_W0; htrans = 2'b10; hwrite = 1'b0; hsize = 3'b010;   // NONSEQ
      @(posedge free_clk); #1;
      haddr = ROM_W1; htrans = 2'b01;                                  // BUSY
      #2;                                     // past the bench's 1 ns input delay
      chk(hrdata === 32'hC0DE0000, "NONSEQ beat returned the wrong word");
      chk(rom_cen === 1'b1, "BUSY beat issued a ROM command");
      @(posedge free_clk); #1;
      htrans = 2'b11;                                                  // SEQ
      @(posedge free_clk); #1;
      bus_idle;
      chk(hrdata === 32'hC0DE0001, "SEQ beat returned the wrong word");
      @(posedge free_clk); #1;

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
