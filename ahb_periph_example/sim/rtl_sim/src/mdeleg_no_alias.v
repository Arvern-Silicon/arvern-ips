//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mdeleg_no_alias
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mdeleg_no_alias.v
// Module Description : MDELEG must not share a decode with any data register.
//
//                      MDELEG sits at offset 0x40, so the register window
//                      needs ADDRW >= 7. A narrower window would truncate its
//                      offset onto REGOUT_00, and an ordinary M-mode write of 0
//                      to REGOUT_00 would clear the privilege gates, opening
//                      the peripheral to User mode with no error anywhere. A
//                      simulation build refuses such a width at elaboration
//                      (and lint reports the truncation); this test pins the
//                      behaviour of every width that is accepted.
//----------------------------------------------------------------------------

localparam REGOUT_00 = 32'h00400000;
localparam MDELEG    = 32'h00400040;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk);

      $display("");
      $display(" ==================================================================");
      $display("|    MDELEG IS NOT ALIASED BY A DATA REGISTER (ADDRW=%0d)           |", ADDRW);
      $display(" ==================================================================");

      // Out of reset MDELEG is M-mode only with ERROR responses.
      ahb_read (1, USER,    REGOUT_00, 32'h00000000, 2, 0, ERROR);

      // An M-mode write of all-zeros to REGOUT_00 -- the value that would open
      // every gate if it also landed in MDELEG.
      ahb_write(1, MACHINE, REGOUT_00, 32'h00000000, 2, OK);
      ahb_write(1, MACHINE, REGOUT_00, 32'h00000000, 0, OK);

      // The gates are unchanged: User access is still refused.
      ahb_read (1, USER,    REGOUT_00, 32'h00000000, 2, 0, ERROR);
      ahb_write(1, USER,    REGOUT_00, 32'h12345678, 2, ERROR);
      ahb_read (1, MACHINE, REGOUT_00, 32'h00000000, 2, 1, OK);

      // And MDELEG itself still reads its reset value.
      ahb_read (1, MACHINE, MDELEG,    32'h0000010F, 2, 1, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
