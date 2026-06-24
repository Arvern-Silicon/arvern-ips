//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    unmapped_access
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : unmapped_access.v
// Module Description : Unmapped / out-of-range access test. All accesses
//                      outside the documented windows must RAZ/WI without
//                      raising hresp. Covers the gap between enable and
//                      target windows, priority slots above NUM_SOURCES,
//                      enable words above NUM_SOURCES, and target stride
//                      slots beyond NUM_CONTEXTS.
//----------------------------------------------------------------------------

// Base of the PLIC slave window (matches hsel decode in the TB).
`define PLIC_BASE  32'h00400000

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      $display(" ===============================================");
      $display("|    GAP BETWEEN ENABLE AND TARGET WINDOWS      |");
      $display(" ===============================================");

      // 0x100000 is between the enable window (ends well before 0x100000)
      // and the target window (starts at 0x200000) -- must RAZ/WI.
      ahb_read (1, MACHINE, `PLIC_BASE + 32'h00100000, 32'h0000_0000, 2, 1, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + 32'h00100000, 32'hFFFF_FFFF, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + 32'h00100000, 32'h0000_0000, 2, 1, OK);

      $display(" ===============================================");
      $display("|    PRIORITY ABOVE NUM_SOURCES (RAZ/WI)        |");
      $display(" ===============================================");

      // 0x000200 = byte offset 0x200 = src 128 (NUM_SOURCES+1=32 .. 1023).
      ahb_read (1, MACHINE, `PLIC_BASE + 32'h00000200, 32'h0000_0000, 2, 1, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + 32'h00000200, 32'hFFFF_FFFF, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + 32'h00000200, 32'h0000_0000, 2, 1, OK);

      $display(" ===============================================");
      $display("|    ENABLE WORD 1 (CTX 0) IS OOR (RAZ)         |");
      $display(" ===============================================");

      // Word 1 in ctx 0 (enable[ctx0][word1]) -- no sources there
      // since NUM_SOURCES=31 fits in word 0. Must RAZ.
      ahb_read(1, MACHINE, `PLIC_BASE + 32'h00002004, 32'h0000_0000, 2, 1, OK);

      $display(" ===============================================");
      $display("|    CLAIM AT OUT-OF-RANGE CONTEXT (CTX 5)      |");
      $display(" ===============================================");

      // Target stride is 0x1000. Ctx 5 lives at 0x200000 + 5*0x1000 = 0x205000.
      // Claim register at +0x4 = 0x205004. Beyond NUM_CONTEXTS=2 -> RAZ/WI.
      ahb_read(1, MACHINE, `PLIC_BASE + 32'h00205004, 32'h0000_0000, 2, 1, OK);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
