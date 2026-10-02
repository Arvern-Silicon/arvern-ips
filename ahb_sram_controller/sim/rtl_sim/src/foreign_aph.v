//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    foreign_aph
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : foreign_aph.v
// Module Description : A transfer to another subordinate (hsel low) coinciding with
//                      this controller's write data phase, and with the cycle after a
//                      paused write (the restore). Every read is checked against the
//                      bench's shadow memory; words 0 and 1 only.
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

      q_clear;
      q_add(WR, BASE + 32'h0, 3'b010, 32'h12345678);
      q_add(FOREIGN, 32'h0, 3'b010, 32'h0);        // foreign APH during the write DPH
      q_add(RD, BASE + 32'h0, 3'b010, 32'h0);
      q_run;

      q_clear;
      q_add(WR, BASE + 32'h4, 3'b010, 32'h9ABCDEF0);
      q_add(RD, BASE + 32'h0, 3'b010, 32'h0);            // pauses the write
      q_add(FOREIGN, 32'h0, 3'b010, 32'h0);        // restore on a foreign APH
      q_add(RD, BASE + 32'h4, 3'b010, 32'h0);
      q_add(FOREIGN, 32'h0, 3'b010, 32'h0);
      q_add(WR, BASE + 32'h0 + 32'h1, 3'b000, 32'h0000AA00);
      q_add(FOREIGN, 32'h0, 3'b010, 32'h0);
      q_add(RD, BASE + 32'h0, 3'b010, 32'h0);
      q_run;
      chk(sram_inst.mem[1] === 32'h9ABCDEF0, "paused write not committed after a foreign transfer");

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
