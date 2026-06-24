//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    priority_multiword
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : priority_multiword
// Module Description : Priority register file decode beyond word 0. With
//                      NUM_SOURCES >= 32, source IDs 32..NUM_SOURCES live at
//                      byte offsets 0x80 and above in the priority window.
//                      This test walks the high-numbered priority slots,
//                      checks PRIO_BITS-wide truncation, re-verifies the
//                      priority[0] RAZ/WI invariant, and pokes one
//                      out-of-range source to confirm RAZ above NUM_SOURCES.
//                      Skipped at NUM_SOURCES < 32.
//----------------------------------------------------------------------------

// Base of the PLIC slave window (matches hsel decode in the TB).
`define PLIC_BASE 32'h00400000

integer ii;
integer hi_src;
integer expected_prio;
integer prio_mask;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      // Parameter-axis guard: this test exercises word-1+ decode of the
      // priority window. Below 32 sources, only word 0 is meaningful.
      if (NUM_SOURCES < 32) begin
         tb_skip_finish("|       (priority_multiword needs NUM_SOURCES>=32)       |");
      end

      // Cap the high-side iteration so wide builds don't explode runtime.
      hi_src    = (NUM_SOURCES > 50) ? 50 : NUM_SOURCES;
      prio_mask = (32'h1 << PRIO_BITS) - 1;

      $display(" ===============================================");
      $display("|    PRIORITY R/W ON SOURCES 32..hi_src         |");
      $display(" ===============================================");

      // Write priority[src] = src & prio_mask for sources in word 1+.
      for (ii = 32; ii <= hi_src; ii = ii + 1) begin
         ahb_write(1, MACHINE, `PLIC_BASE + (ii*4), ii & prio_mask, 2, OK);
      end

      // Read back and verify PRIO_BITS-wide storage.
      for (ii = 32; ii <= hi_src; ii = ii + 1) begin
         expected_prio = ii & prio_mask;
         ahb_read(1, MACHINE, `PLIC_BASE + (ii*4), expected_prio, 2, 1, OK);
      end

      $display(" ===============================================");
      $display("|    SOURCE 0 STILL RAZ/WI                      |");
      $display(" ===============================================");

      // Belt-and-braces re-check that priority[0] is hard-tied 0 even after
      // touching the high-end of the file.
      ahb_write(1, MACHINE, `PLIC_BASE + 32'h000000, 32'hFFFF_FFFF, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + 32'h000000, 32'h0000_0000, 2, 1, OK);

      $display(" ===============================================");
      $display("|    OUT-OF-RANGE SOURCE PRIORITY RAZ           |");
      $display(" ===============================================");

      // First slot above NUM_SOURCES (if room within the 4 KB priority
      // window). The hsel decode is on the 22-bit window; the priority
      // window ends at 0x000FFF (1023 sources). Skip the OOR poke if
      // NUM_SOURCES is already at the max addressable value.
      if (NUM_SOURCES < 1023) begin
         ahb_write(1, MACHINE, `PLIC_BASE + ((NUM_SOURCES+1)*4),
                   32'hFFFF_FFFF, 2, OK);
         ahb_read (1, MACHINE, `PLIC_BASE + ((NUM_SOURCES+1)*4),
                   32'h0000_0000, 2, 1, OK);
      end

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
