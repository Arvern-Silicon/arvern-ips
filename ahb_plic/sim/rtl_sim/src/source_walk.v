//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    source_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : source_walk
// Module Description : Every source end to end through context 0. Each source
//                      alone: priority read-back, the interrupt output, only its
//                      own pending bit in its word, claim returns its ID, complete
//                      with the line low leaves nothing pending. Then two ladders
//                      with every line high (priority ascending, then descending
//                      with the ID), claimed to exhaustion in the order the doc's
//                      rule gives (highest priority first, lowest ID on a tie).
//                      Finally every priority and enable bit is set and cleared,
//                      and source 0 raised: nothing pends.
//----------------------------------------------------------------------------

`define PLIC_BASE     32'h00400000
`define PRIO_BASE     32'h00000000
`define PENDING_BASE  32'h00001000
`define ENABLE_BASE   32'h00002000
`define TARGET_BASE   32'h00200000

localparam SW_MAXP   = (1 << PRIO_BITS) - 1;
localparam SW_NWORDS = (NUM_SOURCES + 32) / 32;     // implemented pending / enable words

task chk;
   input        cond;
   input [8*80-1:0] msg;
   begin
      if (cond !== 1'b1) begin
         $display("ERROR: %0s %t ns", msg, $time);
         error = error + 1;
      end
   end
endtask

// Implemented source bits of pending / enable word w.
function [31:0] sw_word_mask;
   input integer w;
   integer b;
   begin
      sw_word_mask = 32'h0;
      for (b = 0; b < 32; b = b + 1)
         if ((32*w + b >= 1) && (32*w + b <= NUM_SOURCES))
            sw_word_mask[b] = 1'b1;
   end
endfunction

integer s;
integer w;
integer k;
integer pv;
integer exp_id;
integer exp_p;
integer lad_prio [1:NUM_SOURCES];
reg [NUM_SOURCES:1] lad_left;

// Claim ctx 0 to exhaustion; expected winner = highest priority among the
// sources still pending, lowest ID on a tie. Each line drops before its complete.
task sw_drain_ladder;
   begin
      lad_left = {NUM_SOURCES{1'b1}};
      for (k = 1; k <= NUM_SOURCES; k = k + 1) begin
         exp_id = 0;
         exp_p  = 0;
         for (s = NUM_SOURCES; s >= 1; s = s - 1)
            if (lad_left[s] && (lad_prio[s] >= exp_p)) begin
               exp_id = s;
               exp_p  = lad_prio[s];
            end
         ahb_read (1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, exp_id, 2, 1, OK);
         irq_src[exp_id] = 1'b0;
         ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, exp_id, 2, OK);
         lad_left[exp_id] = 1'b0;
      end
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd0, 2, 1, OK);
      repeat(2) @(posedge free_clk); #1;
      chk(irq_m_external === 0, "ladder: interrupt output still high after exhaustion");
      for (w = 0; w < SW_NWORDS; w = w + 1)
         ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 4*w, 32'h0, 2, 1, OK);
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|    SETUP: EVERY SOURCE ENABLED ON CTX 0       |");
      $display(" ===============================================");

      for (w = 0; w < SW_NWORDS; w = w + 1) begin
         ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 4*w, 32'hFFFF_FFFF, 2, OK);
         ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 4*w, sw_word_mask(w), 2, 1, OK);
      end
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE, 32'd0, 2, OK);

      $display(" ===============================================");
      $display("|    WALK: ONE SOURCE AT A TIME                 |");
      $display(" ===============================================");

      for (s = 1; s <= NUM_SOURCES; s = s + 1) begin
         pv = 1 + (s % SW_MAXP);
         ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, pv, 2, OK);
         ahb_read (1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, pv, 2, 1, OK);

         irq_src[s] = 1'b1;
         repeat(2) @(posedge free_clk); #1;
         chk(irq_m_external === 1, "walk: irq_m_external[0] not the only output high");
         chk(irq_s_external === 0, "walk: an S output high with no S enable");
         ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 4*(s/32), 32'h1 << (s%32), 2, 1, OK);
         ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, s, 2, 1, OK);

         irq_src[s] = 1'b0;
         ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, s, 2, OK);
         repeat(2) @(posedge free_clk); #1;
         chk(irq_m_external === 0, "walk: interrupt output high after claim + complete");
         ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 4*(s/32), 32'h0, 2, 1, OK);
      end

      $display(" ===============================================");
      $display("|    LADDER: PRIORITY ASCENDING WITH ID         |");
      $display(" ===============================================");

      for (s = 1; s <= NUM_SOURCES; s = s + 1) begin
         lad_prio[s] = 1 + ((s - 1) * SW_MAXP) / NUM_SOURCES;
         ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, lad_prio[s], 2, OK);
      end
      for (s = 1; s <= NUM_SOURCES; s = s + 1) irq_src[s] = 1'b1;
      repeat(2) @(posedge free_clk); #1;
      chk(irq_m_external === 1, "ascending ladder: interrupt output not high");
      sw_drain_ladder;

      $display(" ===============================================");
      $display("|    LADDER: PRIORITY DESCENDING WITH ID        |");
      $display(" ===============================================");

      for (s = 1; s <= NUM_SOURCES; s = s + 1) begin
         lad_prio[s] = 1 + ((NUM_SOURCES - s) * SW_MAXP) / NUM_SOURCES;
         ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, lad_prio[s], 2, OK);
      end
      for (s = 1; s <= NUM_SOURCES; s = s + 1) irq_src[s] = 1'b1;
      repeat(2) @(posedge free_clk); #1;
      chk(irq_m_external === 1, "descending ladder: interrupt output not high");
      sw_drain_ladder;

      $display(" ===============================================");
      $display("|    EVERY STORED BIT SET THEN CLEARED          |");
      $display(" ===============================================");

      for (s = 1; s <= NUM_SOURCES; s = s + 1) begin
         ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, 32'hFFFF_FFFF, 2, OK);
         ahb_read (1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, SW_MAXP, 2, 1, OK);
         ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, 32'h0, 2, OK);
      end
      for (s = 1; s <= NUM_SOURCES; s = s + 1)
         ahb_read (1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, 32'h0, 2, 1, OK);
      for (w = 0; w < SW_NWORDS; w = w + 1) begin
         ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 4*w, 32'h0, 2, OK);
         ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 4*w, 32'h0, 2, 1, OK);
      end

      // Source 0 is reserved: its line never pends.
      irq_src[0] = 1'b1;
      repeat(4) @(posedge free_clk); #1;
      chk(irq_m_external === 0 && irq_s_external === 0, "source 0: an interrupt output rose");
      for (w = 0; w < SW_NWORDS; w = w + 1)
         ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 4*w, 32'h0, 2, 1, OK);
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd0, 2, 1, OK);
      irq_src[0] = 1'b0;

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
