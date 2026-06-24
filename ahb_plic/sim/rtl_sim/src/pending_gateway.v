//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    pending_gateway
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : pending_gateway.v
// Module Description : Pending word + level-triggered gateway test. Drives
//                      individual irq_src_i lines, verifies the gateway
//                      latches the assertion until claim, that multiple
//                      sources accumulate in the same pending word, and
//                      that writes to the pending window are silently
//                      dropped.
//----------------------------------------------------------------------------

// Base of the PLIC slave window (matches hsel decode in the TB).
`define PLIC_BASE    32'h00400000
`define PENDING_BASE 32'h00001000

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      $display(" ===============================================");
      $display("|    GATEWAY LATCHES PENDING ON LEVEL ASSERT    |");
      $display(" ===============================================");

      // Source 5 asserts.
      irq_src[5] = 1'b1;
      @(posedge free_clk);                       // gateway samples on this edge
      @(posedge free_clk);                       // give pending one more cycle to propagate to readback
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 32'h0,
               32'h0000_0020, 2, 1, OK);     // bit 5 set

      $display(" ===============================================");
      $display("|    PENDING STAYS LATCHED AFTER IRQ DROPS      |");
      $display(" ===============================================");

      // Drop source 5. Pending bit must stay set until claim.
      irq_src[5] = 1'b0;
      @(posedge free_clk);
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 32'h0,
               32'h0000_0020, 2, 1, OK);     // bit 5 still set

      $display(" ===============================================");
      $display("|    MULTIPLE SOURCES ACCUMULATE IN ONE WORD    |");
      $display(" ===============================================");

      // Add source 7 on top.
      irq_src[7] = 1'b1;
      @(posedge free_clk);
      @(posedge free_clk);
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 32'h0,
               32'h0000_00A0, 2, 1, OK);     // bits 5 and 7

      $display(" ===============================================");
      $display("|    PENDING WINDOW WRITES ARE SILENTLY DROPPED |");
      $display(" ===============================================");

      // Write the pending word with all-ones; readback should not change.
      ahb_write(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 32'h0,
                32'hFFFF_FFFF, 2, OK);
      // Drop sources to make sure nothing else is changing under us.
      irq_src[7] = 1'b0;
      @(posedge free_clk);
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 32'h0,
               32'h0000_00A0, 2, 1, OK);     // still only 5 and 7

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
