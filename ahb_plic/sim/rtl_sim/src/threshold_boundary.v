//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    threshold_boundary
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : threshold_boundary
// Module Description : Exact threshold boundary: the mask is STRICTLY greater
//                      (plic_target.v:140, prio > threshold). threshold_claim
//                      only tests prio well below / above threshold, never the
//                      prio == threshold equality point, so a `>`->`>=` weakening
//                      would pass. This pins prio == threshold (must mask, irq
//                      low) and prio == threshold+1 (must pass, irq high).
//                      Also confirms the claim winner is threshold-INDEPENDENT
//                      (returns the source even while it is threshold-masked).
//----------------------------------------------------------------------------

`define PLIC_BASE     32'h00400000
`define PRIO_BASE     32'h00000000
`define ENABLE_BASE   32'h00002000
`define TARGET_BASE   32'h00200000

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|     PLIC : THRESHOLD == PRIORITY BOUNDARY     |");
      $display(" ===============================================");

      // Source 4: priority 4, enabled ctx0.
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*4, 32'd4, 2, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0, 32'h0000_0010, 2, OK); // bit 4
      irq_src[4] = 1'b1;

      // threshold == priority (4): STRICTLY-greater rule => masked, irq low.
      // (Checks are ordered before any claim, since a claim read clears the
      //  pending bit and would invalidate the later checks.)
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0, 32'd4, 2, OK);
      repeat(4) @(posedge free_clk);
      if (irq_m_external[0] !== 1'b0) begin
         $display("ERROR: irq high at prio==threshold (4) -- mask must be strictly greater %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  prio==threshold masked the interrupt (irq low) %t ns", $time);
      end

      // threshold = priority-1 (3): now prio 4 > 3 => passes, irq high.
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0, 32'd3, 2, OK);
      repeat(4) @(posedge free_clk);
      if (irq_m_external[0] !== 1'b1) begin
         $display("ERROR: irq low at prio(4) > threshold(3) -- should pass %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  prio > threshold passed the interrupt (irq high) %t ns", $time);
      end

      // Re-mask (threshold == prio) and confirm the claim is threshold-
      // INDEPENDENT: it still returns source 4 even though irq is masked.
      // (This claim clears pending, so it is the last check.)
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0, 32'd4, 2, OK);
      repeat(4) @(posedge free_clk);
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd4, 2, 1, OK);
      $display("PASS:  claim is threshold-independent (returned 4 while masked) %t ns", $time);

      irq_src[4] = 1'b0;
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
