//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    rpw_sequences
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : rpw_sequences.v
// Module Description : Orderings around a write paused by a read (READ_PENDING_WRITE):
//                      the restore coinciding with the next write's address phase,
//                      a partial write to the paused word, a re-pause right after a
//                      restore, and back-to-back writes after a pause. Every read is
//                      checked against the bench's shadow memory.
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

      // Seed words 0..3 through the bus.
      q_clear;
      q_add(WR, BASE + 32'h0, 3'b010, 32'hA0A0A0A0); q_add(WR, BASE + 32'h4, 3'b010, 32'hB1B1B1B1);
      q_add(WR, BASE + 32'h8, 3'b010, 32'hC2C2C2C2); q_add(WR, BASE + 32'hc, 3'b010, 32'hD3D3D3D3);
      q_run;

      // W(A); R(B); W(A, half); R(A): restore meets the next write, then merge.
      q_clear;
      q_add(WR, BASE + 32'h0, 3'b010, 32'h11111111);
      q_add(RD, BASE + 32'h4, 3'b010, 32'h0);
      q_add(WR, BASE + 32'h0 + 32'h2, 3'b001, 32'h22220000);
      q_add(RD, BASE + 32'h0, 3'b010, 32'h0);
      q_run;

      // W(A); R(B); R(C); W(D); R(D): re-pause right after a restore.
      q_clear;
      q_add(WR, BASE + 32'h0, 3'b010, 32'h33333333);
      q_add(RD, BASE + 32'h4, 3'b010, 32'h0);
      q_add(RD, BASE + 32'h8, 3'b010, 32'h0);
      q_add(WR, BASE + 32'hc, 3'b010, 32'h44444444);
      q_add(RD, BASE + 32'hc, 3'b010, 32'h0);
      q_add(RD, BASE + 32'h0, 3'b010, 32'h0);
      q_run;

      // W(A); R(B); W(C); W(E); R(A); R(C); R(E): writes back to back after a pause.
      q_clear;
      q_add(WR, BASE + 32'h0, 3'b000, 32'h00000055);
      q_add(RD, BASE + 32'h4, 3'b010, 32'h0);
      q_add(WR, BASE + 32'h8, 3'b010, 32'h66666666);
      q_add(WR, BASE + 32'hc + 32'h3, 3'b000, 32'h77000000);
      q_add(RD, BASE + 32'h0, 3'b010, 32'h0);
      q_add(RD, BASE + 32'h8, 3'b010, 32'h0);
      q_add(RD, BASE + 32'hc, 3'b010, 32'h0);
      q_run;

      // Read of the paused word itself, byte by byte, then the whole word.
      q_clear;
      q_add(WR, BASE + 32'h4 + 32'h1, 3'b000, 32'h00008800);
      q_add(RD, BASE + 32'h4, 3'b000, 32'h0);
      q_add(RD, BASE + 32'h4 + 32'h1, 3'b000, 32'h0);
      q_add(RD, BASE + 32'h4, 3'b010, 32'h0);
      q_run;

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
