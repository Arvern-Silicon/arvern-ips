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
// Module Description : Verify that the reserved regions between the four
//                      ACLINT sub-banks are RAZ/WI (read 0, drop writes,
//                      OK response).
//----------------------------------------------------------------------------

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|       UNMAPPED REGIONS : RAZ/WI BEHAVIOR      |");
      $display(" ===============================================");

      // 0x8000 - reserved between MTIMER and SSWI.
      ahb_read (1, MACHINE, 32'h00408000, 32'h00000000, 2, 1, OK);
      ahb_write(1, MACHINE, 32'h00408000, 32'hFFFFFFFF, 2, OK);
      ahb_read (1, MACHINE, 32'h00408000, 32'h00000000, 2, 1, OK);

      // 0xD000 - reserved above SSWI.
      ahb_read (1, MACHINE, 32'h0040D000, 32'h00000000, 2, 1, OK);
      ahb_write(1, MACHINE, 32'h0040D000, 32'hFFFFFFFF, 2, OK);
      ahb_read (1, MACHINE, 32'h0040D000, 32'h00000000, 2, 1, OK);

      // A few more reserved offsets for coverage.
      ahb_read (1, MACHINE, 32'h0040A000, 32'h00000000, 2, 1, OK);
      ahb_read (1, MACHINE, 32'h0040E000, 32'h00000000, 2, 1, OK);
      ahb_read (1, MACHINE, 32'h0040F000, 32'h00000000, 2, 1, OK);

      // Re-confirm a live register still works (MSIP[0] was never touched
      // by the reserved-region writes).
      ahb_read (1, MACHINE, 32'h00400000, 32'h00000000, 2, 1, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
