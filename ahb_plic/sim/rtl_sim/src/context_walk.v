//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    context_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : context_walk
// Module Description : Every context end to end.
//                      Enable block: all 32 words written all-ones (implemented
//                      source bits read back, reserved words RAZ) then all-zeros,
//                      so every enable bit of every context rises and falls.
//                      ID walk: sources 1, 2, 4, .., 64 (<= NUM_SOURCES),
//                      NUM_SOURCES and NUM_SOURCES with one bit cleared, so every
//                      bit of the claim value and of the completion ID rises and
//                      falls. Each source alone enabled on context c: exactly the
//                      output the context numbering maps c to rises (ctx =
//                      2*hart + s_mode with SU_MODE_EN=1, ctx = hart otherwise);
//                      claim via c returns it; a complete written through a
//                      context that does not enable it is ignored (Chapter 9: the
//                      source stays in service, its high line does not re-pend);
//                      the complete via c is accepted and the line re-pends.
//----------------------------------------------------------------------------

`define PLIC_BASE      32'h00400000
`define PRIO_BASE      32'h00000000
`define PENDING_BASE   32'h00001000
`define ENABLE_BASE    32'h00002000
`define ENABLE_STRIDE  32'h00000080
`define TARGET_BASE    32'h00200000
`define TARGET_STRIDE  32'h00001000

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

// Implemented source bits of enable word w (0 for reserved words).
function [31:0] cw_word_mask;
   input integer w;
   integer b;
   begin
      cw_word_mask = 32'h0;
      for (b = 0; b < 32; b = b + 1)
         if ((32*w + b >= 1) && (32*w + b <= NUM_SOURCES))
            cw_word_mask[b] = 1'b1;
   end
endfunction

integer c;
integer d;
integer s;
integer w;
integer b;
integer i;
integer cw_ids [0:31];
integer cw_n;
reg [NUM_HARTS-1:0] exp_m;
reg [NUM_HARTS-1:0] exp_s;

task chk_outputs;
   input [8*80-1:0] msg;
   begin
      chk((irq_m_external === exp_m) && (irq_s_external === exp_s), msg);
   end
endtask

task cw_add;
   input integer id;
   integer j;
   reg     dup;
   begin
      dup = 1'b0;
      for (j = 0; j < cw_n; j = j + 1)
         if (cw_ids[j] == id) dup = 1'b1;
      if (!dup && (id >= 1) && (id <= NUM_SOURCES)) begin
         cw_ids[cw_n] = id;
         cw_n = cw_n + 1;
      end
   end
endtask

// Source s alone enabled on context c (d = another context, not enabling s).
task cw_source;
   begin
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, 32'd1, 2, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + c*`ENABLE_STRIDE + 4*(s/32), 32'h1 << (s%32), 2, OK);

      irq_src[s] = 1'b1;
      repeat(2) @(posedge free_clk); #1;
      chk_outputs("source pending: output set is not exactly the mapped one");

      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE + 32'h4, s, 2, 1, OK);
      #1;
      chk((irq_m_external === 0) && (irq_s_external === 0), "output still high after the claim");

      if (NUM_CONTEXTS > 1) begin
         ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + d*`TARGET_STRIDE + 32'h4, s, 2, OK);
         repeat(3) @(posedge free_clk); #1;
         chk(dut.in_service_flat[s] === 1'b1, "complete via a non-enabling context cleared in_service");
         chk((irq_m_external === 0) && (irq_s_external === 0), "output rose after an ignored complete");
         ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 4*(s/32), 32'h0, 2, 1, OK);
         ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE + 32'h4, 32'd0, 2, 1, OK);
      end

      // Complete via c with the line high: accepted, the source re-pends.
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE + 32'h4, s, 2, OK);
      repeat(3) @(posedge free_clk); #1;
      chk_outputs("complete via the enabling context did not re-pend the source");
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 4*(s/32), 32'h1 << (s%32), 2, 1, OK);

      irq_src[s] = 1'b0;
      ahb_read (1, MACHINE, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE + 32'h4, s, 2, 1, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE + 32'h4, s, 2, OK);
      repeat(2) @(posedge free_clk); #1;
      chk((irq_m_external === 0) && (irq_s_external === 0), "output high after the final complete");
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 4*(s/32), 32'h0, 2, 1, OK);

      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + c*`ENABLE_STRIDE + 4*(s/32), 32'h0, 2, OK);
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      if (NUM_CONTEXTS == 1)
         $display("NOTE:  single context -- the complete-through-another-context check is skipped");

      // ID set: single-bit IDs, NUM_SOURCES, NUM_SOURCES with one bit cleared.
      cw_n = 0;
      for (b = 0; b < 11; b = b + 1) cw_add(1 << b);
      cw_add(NUM_SOURCES);
      for (b = 0; b < 11; b = b + 1)
         if (NUM_SOURCES & (1 << b)) cw_add(NUM_SOURCES & ~(1 << b));

      for (c = 0; c < NUM_CONTEXTS; c = c + 1) begin
         d = (c + 1) % NUM_CONTEXTS;
         $display("----- context %0d -----", c);

         exp_m = {NUM_HARTS{1'b0}};
         exp_s = {NUM_HARTS{1'b0}};
         if (SU_MODE_EN != 0) begin
            if (c % 2) exp_s[c/2] = 1'b1;
            else       exp_m[c/2] = 1'b1;
         end else
            exp_m[c] = 1'b1;

         // Whole enable block up and down.
         for (w = 0; w < 32; w = w + 1) begin
            ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + c*`ENABLE_STRIDE + 4*w, 32'hFFFF_FFFF, 2, OK);
            ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + c*`ENABLE_STRIDE + 4*w, cw_word_mask(w), 2, 1, OK);
         end
         for (w = 0; w < 32; w = w + 1) begin
            ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + c*`ENABLE_STRIDE + 4*w, 32'h0, 2, OK);
            ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + c*`ENABLE_STRIDE + 4*w, 32'h0, 2, 1, OK);
         end

         ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE, 32'd0, 2, OK);

         for (i = 0; i < cw_n; i = i + 1) begin
            s = cw_ids[i];
            cw_source;
         end
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
