//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    enable_rdwr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : enable_rdwr.v
// Module Description : Enable matrix read/write test. Exercises the
//                      per-(context, source-word) enable bits with
//                      NUM_CONTEXTS=2 (hart0/M, hart0/S), checks the source-0
//                      bit is hard-tied 0, that the two contexts are
//                      independent storage, and that out-of-range words /
//                      contexts RAZ.
//----------------------------------------------------------------------------

// Base of the PLIC slave window (matches hsel decode in the TB).
`define PLIC_BASE        32'h00400000
`define ENABLE_BASE      32'h00002000
`define ENABLE_STRIDE    32'h00000080

integer ii;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      $display(" ===============================================");
      $display("|    ENABLE WRITE/READ (CTX 0 = hart0/M)        |");
      $display(" ===============================================");

      // Write enable[ctx=0][word=0] = 0xFFFF_FFFE (all sources 1..31; src 0 RAZ/WI).
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h0,
                32'hFFFF_FFFE, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h0,
                32'hFFFF_FFFE, 2, 1, OK);

      // Source 0 bit must be hard-tied 0 even when the host writes 1.
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h0,
                32'hFFFF_FFFF, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h0,
                32'hFFFF_FFFE, 2, 1, OK);

      $display(" ===============================================");
      $display("|    ENABLE WRITE/READ (CTX 1 = hart0/S)        |");
      $display(" ===============================================");

      // Different pattern for ctx 1 word 0.
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h1*`ENABLE_STRIDE + 32'h0,
                32'hA5A5_A5A4, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h1*`ENABLE_STRIDE + 32'h0,
                32'hA5A5_A5A4, 2, 1, OK);

      // Verify ctx 0 was not disturbed by the ctx 1 write.
      ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h0,
                32'hFFFF_FFFE, 2, 1, OK);

      $display(" ===============================================");
      $display("|    ENABLE WORD 1 IS OUT-OF-RANGE (RAZ/WI)     |");
      $display(" ===============================================");

      // NUM_SOURCES=31 => only word 0 holds bits. Word 1 (offset 0x4) is RAZ.
      ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h4,
                32'h0000_0000, 2, 1, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h4,
                32'hFFFF_FFFF, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h4,
                32'h0000_0000, 2, 1, OK);

      // Confirm the OOR write did not corrupt ctx 0 word 0 either.
      ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h0,
                32'hFFFF_FFFE, 2, 1, OK);

      $display(" ===============================================");
      $display("|    OUT-OF-RANGE CONTEXT IS RAZ                |");
      $display(" ===============================================");

      // Ctx 5 is well beyond NUM_CONTEXTS=2 -- enable read should RAZ.
      ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h5*`ENABLE_STRIDE + 32'h0,
                32'h0000_0000, 2, 1, OK);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
