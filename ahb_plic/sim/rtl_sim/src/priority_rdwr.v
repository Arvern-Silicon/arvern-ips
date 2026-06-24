//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    priority_rdwr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : priority_rdwr.v
// Module Description : Priority window read/write test. Walks the
//                      per-source priority register file, checks that only
//                      PRIO_BITS LSBs are stored, that source 0 is RAZ/WI,
//                      and that source 1 truncates write data to its 3-bit
//                      width.
//----------------------------------------------------------------------------

// Base of the PLIC slave window (matches hsel decode in the TB).
`define PLIC_BASE 32'h00400000

integer ii;
integer expected_prio;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      $display(" ===============================================");
      $display("|    PRIORITY READ/WRITE TEST                   |");
      $display(" ===============================================");

      // Write priority[src] = src & 0x7 for src in 1..31.
      for (ii = 1; ii <= 31; ii = ii + 1) begin
         ahb_write(1, MACHINE, `PLIC_BASE + (ii*4), ii & 32'h7, 2, OK);
      end

      // Read back priority[src] and verify only PRIO_BITS (=3) are retained.
      for (ii = 1; ii <= 31; ii = ii + 1) begin
         expected_prio = ii & 32'h7;
         ahb_read(1, MACHINE, `PLIC_BASE + (ii*4), expected_prio, 2, 1, OK);
      end

      $display(" ===============================================");
      $display("|    SOURCE 0 IS RESERVED (RAZ/WI)              |");
      $display(" ===============================================");

      // Write priority[0] with all-ones; spec: ignored, RAZ.
      ahb_write(1, MACHINE, `PLIC_BASE + 32'h000000, 32'hFFFF_FFFF, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + 32'h000000, 32'h0000_0000, 2, 1, OK);

      $display(" ===============================================");
      $display("|    PRIO_BITS TRUNCATION ON SRC 1              |");
      $display(" ===============================================");

      // Writing all-ones to priority[1] keeps only the low PRIO_BITS bits.
      ahb_write(1, MACHINE, `PLIC_BASE + 32'h000004, 32'hFFFF_FFFF, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + 32'h000004, 32'h0000_0007, 2, 1, OK);

      // Tidy: restore the encoded pattern so a follow-up rerun is clean.
      ahb_write(1, MACHINE, `PLIC_BASE + 32'h000004, 32'h0000_0001, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + 32'h000004, 32'h0000_0001, 2, 1, OK);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
