//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    reset_in_operation
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : reset_in_operation
// Module Description : Reset with live state and live source lines.
//                      (a) A line already high when reset is released pends on
//                          the first clock edge after release, not before.
//                      (b) Reset asserted with priorities, enables, non-zero
//                          thresholds, a pending and an in-service source and two
//                          lines high: during reset hreadyout=1, hresp=0 and both
//                          external outputs 0; after release every register reads
//                          0, in_service is clear (the formerly in-service source
//                          pends again) and the high lines pend on the first edge.
//                      (c) Source 0 toggling pends nothing and, with the bus idle
//                          and the PLIC in a stable state, keeps hclk_en_o low.
//                      The test drives hresetn itself for (b), releasing it
//                      between clock edges as the bench does at boot.
//----------------------------------------------------------------------------

`define PLIC_BASE      32'h00400000
`define PRIO_BASE      32'h00000000
`define PENDING_BASE   32'h00001000
`define ENABLE_BASE    32'h00002000
`define ENABLE_STRIDE  32'h00000080
`define TARGET_BASE    32'h00200000
`define TARGET_STRIDE  32'h00001000

localparam RO_MAXP   = (1 << PRIO_BITS) - 1;
localparam RO_NWORDS = (NUM_SOURCES + 32) / 32;
localparam RO_THR    = RO_MAXP - 1;                 // non-zero from PRIO_BITS=2

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

integer c;
integer s;
integer w;
integer k;
reg [NUM_SOURCES:0] exp_pend;

initial
   begin
      @(posedge free_clk);

      $display(" ===============================================");
      $display("|  (a) LINE HIGH ACROSS RESET RELEASE           |");
      $display(" ===============================================");

      irq_src[2] = 1'b1;
      @(posedge hresetn);
      #1;
      chk(dut.pending_flat[2] === 1'b0, "(a) source 2 pending before the first edge after release");
      @(posedge free_clk); #1;
      chk(dut.pending_flat[2] === 1'b1, "(a) source 2 not pending on the first edge after release");
      chk((irq_m_external === 0) && (irq_s_external === 0), "(a) an output rose with nothing enabled");
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE, 32'h0000_0004, 2, 1, OK);

      $display(" ===============================================");
      $display("|  (b) RESET WITH LIVE STATE                    |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*1, RO_MAXP, 2, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*2, RO_MAXP, 2, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*NUM_SOURCES, 32'd1, 2, OK);
      for (c = 0; c < NUM_CONTEXTS; c = c + 1) begin
         ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + c*`ENABLE_STRIDE, 32'h0000_0006, 2, OK);
         ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + c*`ENABLE_STRIDE + 4*(NUM_SOURCES/32),
                   ((NUM_SOURCES/32) == 0 ? 32'h6 : 32'h0) | (32'h1 << (NUM_SOURCES%32)), 2, OK);
         ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE, RO_THR, 2, OK);
      end

      irq_src[1] = 1'b1;
      repeat(2) @(posedge free_clk);
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd1, 2, 1, OK);   // tie at RO_MAXP: lowest ID
      #1;
      chk(dut.in_service_flat[1] === 1'b1 && dut.pending_flat[2] === 1'b1,
          "(b) setup: source 1 not in service or source 2 not pending");
      if (RO_THR > 0) chk(irq_m_external[0] === 1'b1, "(b) setup: irq_m_external[0] not high");

      @(posedge free_clk); #5;
      hresetn = 1'b0;
      @(posedge free_clk);
      for (k = 0; k < 5; k = k + 1) begin
         @(negedge free_clk);
         chk(hreadyout === 1'b1 && hresp === 1'b0, "(b) during reset: hreadyout/hresp not 1/0");
         chk(irq_m_external === 0 && irq_s_external === 0, "(b) during reset: an external output is high");
         chk(dut.pending_flat[NUM_SOURCES:1] === 0 && dut.in_service_flat[NUM_SOURCES:1] === 0,
             "(b) during reset: pending / in_service not 0");
      end
      @(posedge free_clk); #11;
      hresetn = 1'b1;
      #1;
      chk(dut.pending_flat[NUM_SOURCES:1] === 0 && dut.in_service_flat[NUM_SOURCES:1] === 0,
          "(b) after release, before the first edge: pending / in_service not 0");
      @(posedge free_clk); #1;
      exp_pend = 0;
      exp_pend[1] = 1'b1;
      exp_pend[2] = 1'b1;
      chk(dut.pending_flat[NUM_SOURCES:1] === exp_pend[NUM_SOURCES:1],
          "(b) high lines 1 and 2 not pending on the first edge after release");
      chk(dut.in_service_flat[NUM_SOURCES:1] === 0, "(b) in_service not clear after release");

      // Every register reads its reset value; pending shows only the high lines.
      for (s = 1; s <= NUM_SOURCES; s = s + 1)
         ahb_read(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*s, 32'h0, 2, 1, OK);
      for (w = 0; w < RO_NWORDS; w = w + 1)
         ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 4*w, (w == 0) ? 32'h6 : 32'h0, 2, 1, OK);
      for (c = 0; c < NUM_CONTEXTS; c = c + 1) begin
         for (w = 0; w < RO_NWORDS; w = w + 1)
            ahb_read(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + c*`ENABLE_STRIDE + 4*w, 32'h0, 2, 1, OK);
         ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE,        32'h0, 2, 1, OK);
         ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE + 32'h4, 32'h0, 2, 1, OK);
      end
      #1;
      chk(irq_m_external === 0 && irq_s_external === 0, "(b) after release: an external output is high");

      $display(" ===============================================");
      $display("|  (c) SOURCE 0 TOGGLES: NOTHING PENDS          |");
      $display(" ===============================================");

      repeat(3) @(posedge free_clk);
      for (k = 0; k < 8; k = k + 1) begin
         irq_src[0] = ~irq_src[0];
         @(negedge free_clk);
         chk(hclk_en === 1'b0, "(c) source 0 raised hclk_en_o in a stable state");
         @(posedge free_clk);
      end
      irq_src[0] = 1'b1;
      repeat(3) @(posedge free_clk);
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE, 32'h0000_0006, 2, 1, OK);
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'h0, 2, 1, OK);
      #1;
      chk(irq_m_external === 0 && irq_s_external === 0, "(c) an external output is high");

      irq_src[0] = 1'b0;
      irq_src[1] = 1'b0;
      irq_src[2] = 1'b0;
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
