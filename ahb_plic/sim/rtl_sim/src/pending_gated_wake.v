//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    pending_gated_wake
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : pending_gated_wake
// Module Description : Behavioral check of the hclk_en_o clock-gate advisory --
//                      the dangling, never-checked output flagged in review
//                      (ahb_plic.v:454: hclk_en_o = aph_valid | dph_valid |
//                      (|pending_set_needed)). On a fully IDLE bus the clock is
//                      gated OFF; the ONLY thing that can wake it to latch a new
//                      pending bit is the `pending_set_needed` term. This parks
//                      the bus until hclk is gated, then asserts a source and
//                      proves the pending bit still gets set and the interrupt
//                      fires. If that term were missing from hclk_en_o, the
//                      clock would stay gated, the gateway flop would never
//                      clock, and the interrupt would be lost -- caught here.
//----------------------------------------------------------------------------

`define PLIC_BASE     32'h00400000
`define PRIO_BASE     32'h00000000
`define PENDING_BASE  32'h00001000
`define ENABLE_BASE   32'h00002000
`define TARGET_BASE   32'h00200000

integer gw_guard;
reg     gated_seen;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|     PLIC : PENDING-SET WAKES A GATED CLOCK    |");
      $display(" ===============================================");

      // Configure source 7: priority 5, enabled ctx0, threshold 0.
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*7, 32'd5, 2, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0, 32'h0000_0080, 2, OK); // bit 7
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0, 32'd0, 2, OK);

      // Park the bus fully idle with no sources asserted. hclk_en_o must drop
      // (aph/dph low, no pending_set_needed) and the gated hclk stops.
      irq_src = {(NUM_SOURCES+1){1'b0}};
      gated_seen = 1'b0;
      gw_guard   = 0;
      while (!gated_seen && (gw_guard < 100)) begin
         @(negedge free_clk);
         gw_guard = gw_guard + 1;
         if (hclk_en === 1'b0) gated_seen = 1'b1;
      end
      if (gated_seen) begin
         $display("PASS:  hclk_en dropped -- clock gated on idle bus %t ns", $time);
      end else begin
         $display("ERROR: hclk_en never dropped on an idle bus -- clock-gate advisory stuck high %t ns", $time);
         error = error + 1;
      end

      // Now assert source 7 with the bus still idle. The pending_set_needed term
      // must re-enable hclk so the gateway can latch pending[7] and fire the IRQ.
      irq_src[7] = 1'b1;

      gw_guard = 0;
      while ((irq_m_external[0] !== 1'b1) && (gw_guard < 200)) begin
         @(posedge free_clk);
         gw_guard = gw_guard + 1;
      end
      if (irq_m_external[0] === 1'b1) begin
         $display("PASS:  pending set and IRQ fired from a gated/idle bus (clock self-woke) %t ns", $time);
      end else begin
         $display("ERROR: IRQ never fired -- gated clock did not wake to set pending (hclk_en missing pending term?) %t ns", $time);
         error = error + 1;
      end

      // Confirm the pending bit is actually set in the array.
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 32'h0, 32'h0000_0080, 2, 1, OK);

      irq_src[7] = 1'b0;
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
