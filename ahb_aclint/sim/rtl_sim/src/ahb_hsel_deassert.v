//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_hsel_deassert
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_hsel_deassert
// Module Description : A NONSEQ transfer presented while hsel_i=0 (another
//                      slave selected on the shared bus) must NOT touch ACLINT
//                      state and must not error -- aph_valid gates on hsel_i
//                      (ahb_aclint.v:91). The TB derives hsel from the address
//                      window (haddr[31:16]==0x0040), so issuing a transfer at
//                      an address OUTSIDE that window deasserts hsel while the
//                      master still drives NONSEQ. Existing tests only deassert
//                      hsel during IDLE, so this case was unstimulated.
//----------------------------------------------------------------------------

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(20) @(posedge free_clk);

      $display(" ===============================================");
      $display("|        AHB : HSEL DEASSERT (not selected)     |");
      $display(" ===============================================");

      // Seed in-window state: MSIP[0] = 1, MTIMECMP_LO[0] = 0xA5A5A5A5.
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000001, 2, OK);
      ahb_write(1, MACHINE, 32'h00404000, 32'hA5A5A5A5, 2, OK);
      repeat(60) @(posedge free_clk);   // let MTIMECMP CDC settle

      // NONSEQ writes at out-of-window addresses (haddr[31:16] != 0x0040 ->
      // hsel=0). The DUT must ignore them: no access, OK response, no state
      // change. The low bits intentionally alias MSIP[0] / MTIMECMP_LO[0].
      ahb_write(1, MACHINE, 32'h00500000, 32'h00000000, 2, OK);   // aliases MSIP[0]
      ahb_write(1, MACHINE, 32'h00504000, 32'h00000000, 2, OK);   // aliases MTIMECMP_LO[0]
      ahb_read (1, MACHINE, 32'h00500000, 32'h00000000, 2, 0, OK);// not selected -> no check

      // Confirm in-window state survived (the unselected writes were dropped).
      ahb_read (1, MACHINE, 32'h00400000, 32'h00000001, 2, 1, OK);
      ahb_read (1, MACHINE, 32'h00404000, 32'hA5A5A5A5, 2, 1, OK);
      $display("PASS:  out-of-window (hsel=0) transfers left ACLINT state untouched, no error %t ns", $time);

      // Cleanup.
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000000, 2, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
