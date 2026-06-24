//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_htrans_seq_busy
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_htrans_seq_busy
// Module Description : Drive the SEQ (2'b11) and BUSY (2'b01) htrans encodings
//                      the standard BFM never generates. The DUT keys only on
//                      htrans_i[1] (ahb_aclint.v:91), so:
//                        - SEQ must perform an access (== NONSEQ), and
//                        - BUSY must NOT start an access (== IDLE).
//                      Verified through the MSIP[0] side effect.
//----------------------------------------------------------------------------

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(20) @(posedge free_clk);

      $display(" ===============================================");
      $display("|        AHB : SEQ / BUSY HTRANS ENCODINGS      |");
      $display(" ===============================================");

      // ---- SEQ must behave like NONSEQ: the access happens. ----
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000000, 2, OK);   // MSIP[0] = 0
      ahb_drive_htrans(2'b11, 32'h00400000, 1'b1, 32'h00000001);  // SEQ write = 1
      ahb_read (1, MACHINE, 32'h00400000, 32'h00000001, 2, 1, OK);
      $display("PASS:  SEQ transfer performed the write (MSIP[0]=1) %t ns", $time);

      // ---- BUSY must NOT start an access: state is unchanged. ----
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000000, 2, OK);   // MSIP[0] = 0
      ahb_drive_htrans(2'b01, 32'h00400000, 1'b1, 32'h00000001);  // BUSY write attempt
      ahb_read (1, MACHINE, 32'h00400000, 32'h00000000, 2, 1, OK);
      $display("PASS:  BUSY transfer did not start an access (MSIP[0] still 0) %t ns", $time);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
