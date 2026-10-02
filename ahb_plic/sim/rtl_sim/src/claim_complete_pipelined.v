//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    claim_complete_pipelined
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : claim_complete_pipelined
// Module Description : Claims and completes in back-to-back AHB transfers, each
//                      address phase overlapping the previous data phase.
//                      (a) Claim via ctx 0 then via ctx 1 on a source both enable:
//                          the first wins, the second returns the next source for
//                          ctx 1, or 0 (the claim updates state on the edge ending
//                          its data phase).
//                      (b) Complete with the line high, then two back-to-back
//                          claims: the first returns 0, the second the source --
//                          the completion commits on the edge ending its data
//                          phase and the source re-pends on the next edge.
//                      (c) A word claim held behind a size-denied claim read is
//                          taken exactly once, in the second ERROR cycle.
//                      (d) Complete then an enable-clear write: the complete saw
//                          the enable still set and is accepted.
//----------------------------------------------------------------------------

`define PLIC_BASE      32'h00400000
`define PRIO_BASE      32'h00000000
`define PENDING_BASE   32'h00001000
`define ENABLE_BASE    32'h00002000
`define ENABLE_STRIDE  32'h00000080
`define TARGET_BASE    32'h00200000
`define TARGET_STRIDE  32'h00001000

localparam CP_MAXP = (1 << PRIO_BITS) - 1;
localparam CP_S    = 3;                             // high-priority source
localparam CP_T    = 4;                             // low-priority source

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

task bus_idle;
   begin
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hwrite = 1'b0;
      hsize  = 3'b000;
      set_mode(MACHINE);
   end
endtask

// Present an M-mode word address phase.
task cp_aph;
   input        wr;
   input [31:0] addr;
   begin
      haddr  = addr;
      htrans = 2'b10;
      hwrite = wr;
      hsize  = 3'b010;
      set_mode(MACHINE);
   end
endtask

`define CLAIM(ctx) (`PLIC_BASE + `TARGET_BASE + (ctx)*`TARGET_STRIDE + 32'h4)

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      tb_ahb_plic.irq_src = {(NUM_SOURCES+1){1'b0}};
      repeat(6) @(posedge free_clk); #1;

      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*CP_S, CP_MAXP, 2, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*CP_T, 32'd1, 2, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE, (32'h1 << CP_S) | (32'h1 << CP_T), 2, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE, 32'd0, 2, OK);

      if (NUM_CONTEXTS > 1) begin
         $display(" ===============================================");
         $display("|  (a) CLAIM CTX 0 THEN CLAIM CTX 1             |");
         $display(" ===============================================");

         ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + `ENABLE_STRIDE, (32'h1 << CP_S), 2, OK);
         ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + `TARGET_STRIDE, 32'd0, 2, OK);

         // Only CP_S pending: the second claim finds nothing.
         irq_src[CP_S] = 1'b1;
         repeat(3) @(posedge free_clk); #1;
         cp_aph(0, `CLAIM(0));
         @(posedge free_clk); #1;
         cp_aph(0, `CLAIM(1));
         chk(hreadyout === 1'b1 && hresp === 1'b0 && hrdata === CP_S, "(a) first claim (ctx 0) did not return the source");
         @(posedge free_clk); #1;
         bus_idle;
         chk(hreadyout === 1'b1 && hresp === 1'b0 && hrdata === 32'h0, "(a) second claim (ctx 1) did not return 0");
         @(posedge free_clk); #1;
         irq_src[CP_S] = 1'b0;
         ahb_write(1, MACHINE, `CLAIM(0), CP_S, 2, OK);

         // CP_T pending too and enabled on ctx 1: the second claim returns it.
         ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + `ENABLE_STRIDE, (32'h1 << CP_S) | (32'h1 << CP_T), 2, OK);
         irq_src[CP_S] = 1'b1;
         irq_src[CP_T] = 1'b1;
         repeat(3) @(posedge free_clk); #1;
         cp_aph(0, `CLAIM(0));
         @(posedge free_clk); #1;
         cp_aph(0, `CLAIM(1));
         chk(hrdata === CP_S, "(a) first claim (ctx 0) did not return the high-priority source");
         @(posedge free_clk); #1;
         bus_idle;
         chk(hrdata === CP_T, "(a) second claim (ctx 1) did not return the next source");
         @(posedge free_clk); #1;
         irq_src[CP_S] = 1'b0;
         irq_src[CP_T] = 1'b0;
         ahb_write(1, MACHINE, `CLAIM(0), CP_S, 2, OK);
         ahb_write(1, MACHINE, `CLAIM(1), CP_T, 2, OK);
         ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + `ENABLE_STRIDE, 32'h0, 2, OK);
         ahb_read (1, MACHINE, `PLIC_BASE + `PENDING_BASE, 32'h0, 2, 1, OK);
      end else
         $display("NOTE:  single context -- (a) skipped");

      $display(" ===============================================");
      $display("|  (b) COMPLETE (LINE HIGH) THEN CLAIM          |");
      $display(" ===============================================");

      irq_src[CP_S] = 1'b1;
      repeat(3) @(posedge free_clk);
      ahb_read(1, MACHINE, `CLAIM(0), CP_S, 2, 1, OK);
      @(posedge free_clk); #1;
      cp_aph(1, `CLAIM(0));
      @(posedge free_clk); #1;
      hwdata = CP_S;
      cp_aph(0, `CLAIM(0));
      chk(hreadyout === 1'b1 && hresp === 1'b0, "(b) complete not zero-wait OKAY");
      @(posedge free_clk); #1;
      cp_aph(0, `CLAIM(0));
      chk(hreadyout === 1'b1 && hresp === 1'b0 && hrdata === 32'h0, "(b) claim right after the complete did not return 0");
      // The re-pend lands one edge later: a claim one cycle later returns the source.
      @(posedge free_clk); #1;
      bus_idle;
      chk(hreadyout === 1'b1 && hresp === 1'b0 && hrdata === CP_S, "(b) claim one cycle after the complete did not return the source");
      @(posedge free_clk); #1;
      irq_src[CP_S] = 1'b0;
      ahb_write(1, MACHINE, `CLAIM(0), CP_S, 2, OK);

      $display(" ===============================================");
      $display("|  (c) CLAIM HELD BEHIND A DENIED TRANSFER      |");
      $display(" ===============================================");

      irq_src[CP_S] = 1'b1;
      irq_src[CP_T] = 1'b1;
      repeat(3) @(posedge free_clk); #1;
      cp_aph(0, `CLAIM(0));
      hsize = 3'b000;                                   // byte read: denied
      @(posedge free_clk); #1;
      cp_aph(0, `CLAIM(0));                             // word claim, held through the ERROR
      chk(hreadyout === 1'b0 && hresp === 1'b1 && hrdata === 32'h0, "(c) ERROR cycle 1 expected");
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b1 && hrdata === 32'h0, "(c) ERROR cycle 2 expected");
      @(posedge free_clk); #1;                          // held claim taken at this edge
      bus_idle;
      chk(hreadyout === 1'b1 && hresp === 1'b0 && hrdata === CP_S, "(c) held claim did not return the source");
      @(posedge free_clk); #1;
      chk(dut.in_service_flat[CP_S] === 1'b1 && dut.in_service_flat[CP_T] === 1'b0 &&
          dut.pending_flat[CP_T] === 1'b1, "(c) held claim not taken exactly once");
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE, (32'h1 << CP_T), 2, 1, OK);
      ahb_read(1, MACHINE, `CLAIM(0), CP_T, 2, 1, OK);
      irq_src[CP_S] = 1'b0;
      irq_src[CP_T] = 1'b0;
      ahb_write(1, MACHINE, `CLAIM(0), CP_S, 2, OK);
      ahb_write(1, MACHINE, `CLAIM(0), CP_T, 2, OK);

      $display(" ===============================================");
      $display("|  (d) COMPLETE THEN ENABLE-CLEAR WRITE         |");
      $display(" ===============================================");

      irq_src[CP_S] = 1'b1;
      repeat(3) @(posedge free_clk);
      ahb_read(1, MACHINE, `CLAIM(0), CP_S, 2, 1, OK);
      @(posedge free_clk); #1;
      cp_aph(1, `CLAIM(0));
      @(posedge free_clk); #1;
      hwdata = CP_S;
      cp_aph(1, `PLIC_BASE + `ENABLE_BASE);
      @(posedge free_clk); #1;
      hwdata = 32'h0;
      bus_idle;
      @(posedge free_clk); #1;
      repeat(3) @(posedge free_clk); #1;
      chk(dut.in_service_flat[CP_S] === 1'b0, "(d) complete followed by the enable clear was not accepted");
      ahb_read(1, MACHINE, `PLIC_BASE + `ENABLE_BASE, 32'h0, 2, 1, OK);
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE, (32'h1 << CP_S), 2, 1, OK);
      ahb_read(1, MACHINE, `CLAIM(0), 32'h0, 2, 1, OK);
      #1;
      chk(irq_m_external[0] === 1'b0, "(d) output high with the source disabled");
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE, (32'h1 << CP_S), 2, OK);
      irq_src[CP_S] = 1'b0;
      ahb_read (1, MACHINE, `CLAIM(0), CP_S, 2, 1, OK);
      ahb_write(1, MACHINE, `CLAIM(0), CP_S, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + `PENDING_BASE, 32'h0, 2, 1, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
