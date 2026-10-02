//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    denied_unmapped_ro
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : denied_unmapped_ro.v
// Module Description : Unmapped offsets and the read-only bank, from both sides of
//                      the privilege gates. A denied access is refused (ERROR with
//                      RESP=1) at every offset, so a master below the gate cannot
//                      probe the map; an admitted access to an unmapped offset or a
//                      write to REGIN_* is an OKAY no-op; with RESP=0 a denied access
//                      is dropped silently.
//----------------------------------------------------------------------------

localparam REGOUT_00 = 32'h00400000;
localparam REGIN_08  = 32'h00400020;
localparam UNMAPPED  = 32'h00400044;
localparam UNMAPPED2 = 32'h0040007C;
localparam MDELEG    = 32'h00400040;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk);
      periph0_reg_08_in = 32'hCAFE0008;

      // Reset gates: Machine only, RESP=1.
      ahb_read (1, USER,       UNMAPPED,  32'h00000000, 2, 0, ERROR);
      ahb_write(1, USER,       UNMAPPED,  32'h12345678, 2, ERROR);
      ahb_read (1, SUPERVISOR, UNMAPPED2, 32'h00000000, 2, 0, ERROR);
      ahb_write(1, USER,       REGIN_08,  32'h12345678, 2, ERROR);

      // Machine mode is admitted: unmapped is RAZ/WI, REGIN_* writes are no-ops.
      ahb_write(1, MACHINE,    UNMAPPED,  32'h12345678, 2, OK);
      ahb_read (1, MACHINE,    UNMAPPED,  32'h00000000, 2, 1, OK);
      ahb_write(1, MACHINE,    REGIN_08,  32'h12345678, 2, OK);
      ahb_read (1, MACHINE,    REGIN_08,  32'hCAFE0008, 2, 1, OK);

      // Open both gates to User: the same accesses are admitted, OKAY, no effect.
      ahb_write(1, MACHINE,    MDELEG,    32'h00000100, 2, OK);
      ahb_read (1, USER,       UNMAPPED,  32'h00000000, 2, 1, OK);
      ahb_write(1, USER,       UNMAPPED,  32'h12345678, 2, OK);
      ahb_write(1, USER,       REGIN_08,  32'h12345678, 2, OK);
      ahb_read (1, USER,       REGIN_08,  32'hCAFE0008, 2, 1, OK);

      // Machine-only gates with RESP=0: a denied access is dropped silently.
      ahb_write(1, MACHINE,    REGOUT_00, 32'hA5A5A5A5, 2, OK);
      ahb_write(1, MACHINE,    MDELEG,    32'h0000000F, 2, OK);
      ahb_read (1, USER,       UNMAPPED,  32'h00000000, 2, 1, OK);
      ahb_read (1, USER,       REGOUT_00, 32'h00000000, 2, 1, OK);
      ahb_write(1, USER,       REGOUT_00, 32'h5A5A5A5A, 2, OK);
      ahb_read (1, MACHINE,    REGOUT_00, 32'hA5A5A5A5, 2, 1, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
