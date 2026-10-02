//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    threshold_extremes
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : threshold_extremes
// Module Description : Threshold and priority at the ends of their range, with
//                      MAXP = 2^PRIO_BITS - 1. A source at priority MAXP under
//                      threshold MAXP is masked (output low) yet still returned by
//                      a claim (Chapter 8); threshold MAXP-1 lets it through. Run
//                      on source 1, source 64 (word 2, when NUM_SOURCES >= 64) and
//                      source NUM_SOURCES. An all-ones write to every threshold and
//                      to a priority reads back MAXP (upper bits RAZ/WI). Every
//                      register is restored to 0.
//----------------------------------------------------------------------------

`define PLIC_BASE      32'h00400000
`define PRIO_BASE      32'h00000000
`define PENDING_BASE   32'h00001000
`define ENABLE_BASE    32'h00002000
`define TARGET_BASE    32'h00200000
`define TARGET_STRIDE  32'h00001000

localparam TE_MAXP = (1 << PRIO_BITS) - 1;

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

integer te_src [0:2];
integer te_n;
integer i;
integer c;
integer s;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      te_n = 0;
      te_src[te_n] = 1; te_n = te_n + 1;
      if (NUM_SOURCES >= 64) begin
         te_src[te_n] = 64; te_n = te_n + 1;
      end
      if ((NUM_SOURCES != 1) && (NUM_SOURCES != 64)) begin
         te_src[te_n] = NUM_SOURCES; te_n = te_n + 1;
      end

      for (i = 0; i < te_n; i = i + 1) begin
         s = te_src[i];
         $display(" ===============================================");
         $display("|    SOURCE %4d AT PRIORITY MAXP                |", s);
         $display(" ===============================================");

         ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, TE_MAXP, 2, OK);
         ahb_read (1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, TE_MAXP, 2, 1, OK);
         ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 4*(s/32), 32'h1 << (s%32), 2, OK);
         ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE, TE_MAXP, 2, OK);
         ahb_read (1, MACHINE, `PLIC_BASE + `TARGET_BASE, TE_MAXP, 2, 1, OK);

         irq_src[s] = 1'b1;
         repeat(2) @(posedge free_clk); #1;
         chk(irq_m_external === 0 && irq_s_external === 0, "threshold MAXP: output high for a priority-MAXP source");
         ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 4*(s/32), 32'h1 << (s%32), 2, 1, OK);

         ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE, TE_MAXP - 1, 2, OK);
         @(posedge free_clk); #1;
         chk(irq_m_external === 1 && irq_s_external === 0, "threshold MAXP-1: irq_m_external[0] not the only output high");

         ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE, TE_MAXP, 2, OK);
         @(posedge free_clk); #1;
         chk(irq_m_external === 0, "threshold MAXP again: output still high");

         // Masked, but the claim is threshold-independent.
         ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, s, 2, 1, OK);
         irq_src[s] = 1'b0;
         ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, s, 2, OK);
         repeat(2) @(posedge free_clk); #1;
         chk(irq_m_external === 0, "output high after claim + complete");
         ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 4*(s/32), 32'h0, 2, 1, OK);
         ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd0, 2, 1, OK);

         ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, 32'h0, 2, OK);
         ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 4*(s/32), 32'h0, 2, OK);
         ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE, 32'h0, 2, OK);
      end

      $display(" ===============================================");
      $display("|    ALL-ONES WRITES READ BACK MAXP             |");
      $display(" ===============================================");

      for (c = 0; c < NUM_CONTEXTS; c = c + 1) begin
         ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE, 32'hFFFF_FFFF, 2, OK);
         ahb_read (1, MACHINE, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE, TE_MAXP, 2, 1, OK);
         ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE, 32'h0, 2, OK);
         ahb_read (1, MACHINE, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE, 32'h0, 2, 1, OK);
      end
      for (i = 0; i < te_n; i = i + 1) begin
         s = te_src[i];
         ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, 32'hFFFF_FFFF, 2, OK);
         ahb_read (1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, TE_MAXP, 2, 1, OK);
         ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, 32'h0, 2, OK);
         ahb_read (1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, 32'h0, 2, 1, OK);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
