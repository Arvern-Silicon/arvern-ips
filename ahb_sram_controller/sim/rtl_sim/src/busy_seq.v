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
// Module Description : SEQ and BUSY beats: a NONSEQ+SEQ write burst and a read burst
//                      with a BUSY beat carrying a write address and data. SEQ beats
//                      are transfers, BUSY is not; the shadow memory checks the
//                      result; words 0 and 1 only.
//----------------------------------------------------------------------------

// Pipelined sequencer: each operation's address phase overlaps the previous
// operation's data phase. Kinds: RD, WR, FOREIGN (a NONSEQ to another
// subordinate, hsel low), GAP (IDLE cycle). Read data and write effects are
// checked by the bench's bus monitor and shadow memory.
localparam RD = 2'd0, WR = 2'd1, FOREIGN = 2'd2, GAP = 2'd3;
localparam BASE  = 32'h00400000;
localparam OTHER = 32'h00500000;

reg   [1:0] q_kind [0:15];
reg  [31:0] q_addr [0:15];
reg   [2:0] q_size [0:15];
reg  [31:0] q_data [0:15];
integer     q_n;
integer     q_k;

task q_clear; begin q_n = 0; end endtask

task q_add;
   input  [1:0] kind;
   input [31:0] addr;
   input  [2:0] size;
   input [31:0] data;     // write data already on its byte lanes
   begin
      q_kind[q_n] = kind; q_addr[q_n] = addr; q_size[q_n] = size; q_data[q_n] = data;
      q_n = q_n + 1;
   end
endtask

task q_run;
   begin
      for (q_k = 0; q_k <= q_n; q_k = q_k + 1) begin
         // Outside a write data phase hwdata carries junk the controller must ignore.
         hwdata = ((q_k > 0) && (q_kind[q_k-1] == WR)) ? q_data[q_k-1] : (32'hC0DE0000 | q_k);
         if (q_k < q_n) begin
            hwrite = (q_kind[q_k] == WR);
            hsize  = q_size[q_k];
            htrans = (q_kind[q_k] == GAP) ? 2'b00 : 2'b10;
            haddr  = (q_kind[q_k] == FOREIGN) ? OTHER : q_addr[q_k];
         end else begin
            haddr = 32'h0; htrans = 2'b00; hwrite = 1'b0; hsize = 3'b010;
         end
         @(posedge free_clk); #1;
      end
      repeat(2) @(posedge free_clk); #1;
   end
endtask

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

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk); #1;

      hwrite = 1'b1; hsize = 3'b010;
      haddr = BASE + 32'h0; htrans = 2'b10;              // NONSEQ write
      @(posedge free_clk); #1;
      hwdata = 32'h01010101;
      haddr = BASE + 32'h4; htrans = 2'b11;              // SEQ write
      @(posedge free_clk); #1;
      hwdata = 32'h02020202;
      haddr = BASE + 32'h0; htrans = 2'b01;              // BUSY with a write address
      @(posedge free_clk); #1;
      hwdata = 32'hDEADBEEF;
      hwrite = 1'b0; haddr = BASE + 32'h0; htrans = 2'b10;   // NONSEQ read
      @(posedge free_clk); #1;
      haddr = BASE + 32'h4; htrans = 2'b01;              // BUSY
      @(posedge free_clk); #1;
      htrans = 2'b11;                              // SEQ read
      @(posedge free_clk); #1;
      haddr = 32'h0; htrans = 2'b00;
      repeat(2) @(posedge free_clk); #1;
      chk(sram_inst.mem[0] === 32'h01010101 && sram_inst.mem[1] === 32'h02020202, "burst writes wrong or BUSY wrote");

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
