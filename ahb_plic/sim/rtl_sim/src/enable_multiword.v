//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    enable_multiword
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : enable_multiword
// Module Description : Enable matrix decode beyond word 0. With
//                      NUM_SOURCES >= 32, the per-context enable block spans
//                      word 0 and word 1; this test writes distinct patterns
//                      into both words for ctx 0, verifies that the source-0
//                      bit is hard-tied 0, then writes a different pattern
//                      to a second context and confirms ctx 0 storage is
//                      independent. Patterns are masked to the actual
//                      NUM_SOURCES range so the test passes from
//                      NUM_SOURCES=32 (only bit 0 of word 1 implemented)
//                      up to NUM_SOURCES=63+ (full word 1 implemented).
//                      Skipped at NUM_SOURCES < 32.
//----------------------------------------------------------------------------

// Base of the PLIC slave window (matches hsel decode in the TB).
`define PLIC_BASE        32'h00400000
`define ENABLE_BASE      32'h00002000
`define ENABLE_STRIDE    32'h00000080

integer second_ctx;
integer word1_bits;
integer w1_mask;
integer w1_pattern;
integer w1_other_pattern;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      // Parameter-axis guard: needs at least word 1 of the enable matrix.
      if (NUM_SOURCES < 32) begin
         tb_skip_finish("|        (enable_multiword needs NUM_SOURCES>=32)        |");
      end

      // Number of implemented bits in word 1. NUM_SOURCES=32 => 1 bit
      // (source 32 only); NUM_SOURCES=63 => 32 bits (sources 32..63).
      word1_bits = NUM_SOURCES - 31;
      if (word1_bits >= 32) begin
         w1_mask = 32'hFFFF_FFFF;
      end else begin
         w1_mask = (32'h1 << word1_bits) - 1;
      end
      w1_pattern       = 32'hCAFE_BABE & w1_mask;
      w1_other_pattern = 32'h1234_5678 & w1_mask;

      // Pick a distinct second context. With SU_MODE_EN=1, NUM_CONTEXTS>=2
      // is always true, so ctx 1 is hart 0 S. Without SU, NUM_HARTS>=2 is
      // needed for ctx 1 to exist; the test guard below covers the corner
      // where neither holds.
      second_ctx = 1;

      $display(" ===============================================");
      $display("|    ENABLE WORD 0 + WORD 1 R/W FOR CTX 0       |");
      $display(" ===============================================");

      // Word 0: sources 1..31 all enabled. Source 0 is hard-tied 0.
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h0,
                32'hFFFF_FFFE, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h0,
                32'hFFFF_FFFE, 2, 1, OK);

      // Word 1: pattern truncated to implemented bits.
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h4,
                w1_pattern, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h4,
                w1_pattern, 2, 1, OK);

      $display(" ===============================================");
      $display("|    SOURCE-0 BIT REMAINS HARD-TIED 0           |");
      $display(" ===============================================");

      // Even with all-ones write, bit 0 of word 0 must read back 0.
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h0,
                32'hFFFF_FFFF, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h0,
                32'hFFFF_FFFE, 2, 1, OK);

      // Write a different pattern to ctx 1 (if such a context exists) and
      // verify ctx 0 is unchanged afterwards. Skip the cross-context check
      // when only one context is implemented (SU=0, NUM_HARTS=1).
      if (second_ctx < NUM_CONTEXTS) begin
         $display(" ===============================================");
         $display("|    SECOND CONTEXT R/W IS INDEPENDENT OF CTX0  |");
         $display(" ===============================================");

         // Distinct pattern in ctx 1, word 0 and word 1.
         ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + second_ctx*`ENABLE_STRIDE + 32'h0,
                   32'hA5A5_A5A4, 2, OK);
         ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + second_ctx*`ENABLE_STRIDE + 32'h4,
                   w1_other_pattern, 2, OK);
         ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + second_ctx*`ENABLE_STRIDE + 32'h0,
                   32'hA5A5_A5A4, 2, 1, OK);
         ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + second_ctx*`ENABLE_STRIDE + 32'h4,
                   w1_other_pattern, 2, 1, OK);

         // Ctx 0 unchanged by the ctx-1 traffic.
         ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h0,
                   32'hFFFF_FFFE, 2, 1, OK);
         ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h4,
                   w1_pattern, 2, 1, OK);
      end

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
