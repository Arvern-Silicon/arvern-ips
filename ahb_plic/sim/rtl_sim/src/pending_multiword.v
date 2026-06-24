//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    pending_multiword
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : pending_multiword
// Module Description : Pending register file decode beyond word 0. Drives
//                      three high-numbered sources (in word 1, sources
//                      32..NUM_SOURCES) and verifies the gateway latches
//                      pending bits at the correct positions of pending
//                      word 1. Also confirms word 0 stays clear because
//                      no low-numbered source is driven. Source indices
//                      are chosen as a function of NUM_SOURCES so the test
//                      passes at NUM_SOURCES=32 (only source 32 is in
//                      range) through NUM_SOURCES=63+ (full word 1).
//                      Skipped at NUM_SOURCES < 32.
//----------------------------------------------------------------------------

// Base of the PLIC slave window (matches hsel decode in the TB).
`define PLIC_BASE    32'h00400000
`define PENDING_BASE 32'h00001000

integer src_a;
integer src_b;
integer src_c;
integer expected_word1;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      // Parameter-axis guard: this test exercises pending word 1 decode.
      if (NUM_SOURCES < 32) begin
         tb_skip_finish("|        (pending_multiword needs NUM_SOURCES>=32)       |");
      end

      // Pick three valid sources >= 32. Choose them deterministically as a
      // function of NUM_SOURCES so the patterns scale from 32 (all three
      // collapse onto 32) up to 63+ (35, 50, 63 as the spec suggests).
      src_a = 32;
      src_b = (NUM_SOURCES >= 50) ? 50 : NUM_SOURCES;
      src_c = (NUM_SOURCES >= 63) ? 63 : NUM_SOURCES;

      // Expected pending word 1 = OR of (1 << (src-32)) for each driven src.
      expected_word1 = (32'h1 << (src_a - 32))
                     | (32'h1 << (src_b - 32))
                     | (32'h1 << (src_c - 32));

      $display(" ===============================================");
      $display("|    DRIVE HIGH-NUMBERED SOURCES                |");
      $display(" ===============================================");

      tb_idx = src_a; set_irq_src(tb_idx, 1'b1);
      tb_idx = src_b; set_irq_src(tb_idx, 1'b1);
      tb_idx = src_c; set_irq_src(tb_idx, 1'b1);
      @(posedge free_clk);                       // gateway samples
      @(posedge free_clk);                       // settle to readback

      $display(" ===============================================");
      $display("|    PENDING WORD 1 REFLECTS HIGH-NUMBER IRQS   |");
      $display(" ===============================================");

      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 32'h4,
               expected_word1, 2, 1, OK);

      $display(" ===============================================");
      $display("|    PENDING WORD 0 UNTOUCHED (NO LOW SOURCES)  |");
      $display(" ===============================================");

      // Sources < 32 were never driven; word 0 must still be 0.
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 32'h0,
               32'h0000_0000, 2, 1, OK);

      // Drain: drop the sources before exiting.
      tb_idx = src_a; set_irq_src(tb_idx, 1'b0);
      tb_idx = src_b; set_irq_src(tb_idx, 1'b0);
      tb_idx = src_c; set_irq_src(tb_idx, 1'b0);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
