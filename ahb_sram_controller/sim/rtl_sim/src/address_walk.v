//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    address_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : address_walk.v
// Module Description : Walking-one and walking-zero word addresses over the
//                      whole array, for every MEM_SIZE build. Each address is
//                      written with a second write pipelined straight behind it,
//                      then both are read back through the bus and in the memory
//                      model, so every word-address bit rises and falls on
//                      haddr_i, on sram_addr_o and in the write address buffer.
//                        ahb_sram_controller.md: "sram_wr_addr_buf and
//                        sram_wr_en_buf capture the word address and byte strobes
//                        of every write address phase (the data arrives a cycle
//                        later; they drive sram_addr_o and sram_wen_o during the
//                        data phase and during a restore)."
//----------------------------------------------------------------------------

localparam AW_BASE  = 32'h00400000;
localparam AW_WORDS = MEM_SIZE / 4;

integer aw_b;
integer aw_nb;
reg [31:0] aw_a;
reg [31:0] aw_b2;

function [31:0] aw_pat;
   input [31:0] w;
   aw_pat = {w[15:0], ~w[15:0]};
endfunction

// Word index w: write it, pipeline a second write at w2 behind it, read both back.
task aw_pair;
   input [31:0] w;
   input [31:0] w2;
   begin
      ahb_write(0, AW_BASE + 4*w,  aw_pat(w),  2);
      ahb_write(1, AW_BASE + 4*w2, aw_pat(w2), 2);
      ahb_read (0, AW_BASE + 4*w,  aw_pat(w),  2, 1);
      ahb_read (1, AW_BASE + 4*w2, aw_pat(w2), 2, 1);
      repeat(2) @(posedge free_clk);
      check_mem_value(w,  aw_pat(w));
      check_mem_value(w2, aw_pat(w2));
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(10) @(posedge free_clk);

      // Word-address width: AW_WORDS is a power of two.
      aw_nb = 0;
      while ((1 << aw_nb) < AW_WORDS) aw_nb = aw_nb + 1;

      $display(" ===============================================");
      $display("|   ADDRESS WALK: %0d WORD-ADDRESS BITS          |", aw_nb);
      $display(" ===============================================");

      for (aw_b = 0; aw_b < aw_nb; aw_b = aw_b + 1) begin
         aw_a  = 32'h1 << aw_b;                              // walking one
         aw_b2 = (AW_WORDS - 1) & ~(32'h1 << aw_b);          // walking zero
         aw_pair(aw_a, aw_b2);
         aw_pair(aw_b2, aw_a);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
