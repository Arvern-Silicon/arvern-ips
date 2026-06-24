//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_subword
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_subword
// Module Description : Byte and half-word AHB accesses. The DUT ignores
//                      hsize_i (word-only register device) and acts on
//                      hwdata_i[0]; every test so far used word accesses only,
//                      so the byte/half-word lanes were never driven. This
//                      drives lane-0 byte and half-word writes/reads to MSIP[0]
//                      and confirms bit[0] set/clear semantics hold.
//----------------------------------------------------------------------------

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(20) @(posedge free_clk);

      $display(" ===============================================");
      $display("|        AHB : BYTE / HALF-WORD ACCESSES        |");
      $display(" ===============================================");

      // Start clean.
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000000, 2, OK);

      // BYTE write of 0x01 to the lane-0 byte of MSIP[0] -> sets bit[0].
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000001, 0, OK);
      // BYTE read of the lane-0 byte -> 0x01.
      ahb_read (1, MACHINE, 32'h00400000, 32'h00000001, 0, 1, OK);
      // Word read confirms the whole register reads back 0x1.
      ahb_read (1, MACHINE, 32'h00400000, 32'h00000001, 2, 1, OK);

      // BYTE write of 0x00 clears bit[0].
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000000, 0, OK);
      ahb_read (1, MACHINE, 32'h00400000, 32'h00000000, 2, 1, OK);

      // HALF-WORD write of 0x0001 to the lower half -> sets bit[0].
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000001, 1, OK);
      ahb_read (1, MACHINE, 32'h00400000, 32'h00000001, 1, 1, OK);
      ahb_read (1, MACHINE, 32'h00400000, 32'h00000001, 2, 1, OK);

      $display("PASS:  byte / half-word MSIP[0] accesses behave per the word-only contract %t ns", $time);

      // Restore.
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000000, 2, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
