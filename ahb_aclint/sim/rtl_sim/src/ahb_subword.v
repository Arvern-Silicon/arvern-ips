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
//
//                      It also pins the UNALIGNED case, which is the one with
//                      teeth. The register decode is a range compare, so without
//                      an explicit word-alignment term every sub-word offset
//                      aliases onto the register below it -- and aRVern
//                      replicates a store byte across all four lanes
//                      (arv_load_store.v), so `sb x0, 1(msip)` would land in
//                      bit 0 and clear a pending IPI that firmware never touched.
//                      MTIME was already exact-compared and RAZ/WI'd the same
//                      offsets, so the two halves of one window disagreed.
//                      Offsets +1/+2/+3 must RAZ/WI in every window.
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

      $display("");
      $display(" ===============================================");
      $display("|   AHB : UNALIGNED OFFSETS MUST RAZ/WI         |");
      $display(" ===============================================");

      // Arm MSIP[0] so an aliasing write has something to destroy.
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000001, 2, OK);
      ahb_read (1, MACHINE, 32'h00400000, 32'h00000001, 2, 1, OK);

      // The exact shape of the aRVern store: a byte write whose data is
      // replicated across every lane, aimed one byte into the register.
      ahb_write(1, MACHINE, 32'h00400001, 32'h00000000, 0, OK);
      ahb_write(1, MACHINE, 32'h00400002, 32'h00000000, 0, OK);
      ahb_write(1, MACHINE, 32'h00400003, 32'h00000000, 0, OK);

      if (tb_ahb_aclint.dut.irq_m_software_o[0] !== 1'b1) begin
         $display("ERROR: an unaligned write cleared MSIP[0] -- sub-word offsets are aliasing onto the register %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  unaligned writes did not disturb MSIP[0] %t ns", $time);
      end

      // ...and they must read as zero rather than mirroring the register.
      ahb_read (1, MACHINE, 32'h00400001, 32'h00000000, 2, 1, OK);
      ahb_read (1, MACHINE, 32'h00400002, 32'h00000000, 2, 1, OK);
      $display("PASS:  unaligned MSWI offsets read as zero %t ns", $time);

      // Same rule inside the MTIMER window. MTIMECMP was the range-compared
      // half; MTIME has always been exact.
      ahb_write(1, MACHINE, 32'h00404000, 32'h5A5A5A5A, 2, OK);
      ahb_write(1, MACHINE, 32'h00404001, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, 32'h00404002, 32'hFFFFFFFF, 2, OK);
      ahb_read (1, MACHINE, 32'h00404000, 32'h5A5A5A5A, 2, 1, OK);
      ahb_read (1, MACHINE, 32'h00404001, 32'h00000000, 2, 1, OK);
      $display("PASS:  unaligned MTIMECMP offsets RAZ/WI, like MTIME %t ns", $time);

      // Clean up so a later phase does not inherit an armed comparator.
      ahb_write(1, MACHINE, 32'h00404000, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000000, 2, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
