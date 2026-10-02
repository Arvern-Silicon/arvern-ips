//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    denied_narrow
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : denied_narrow.v
// Module Description : Sub-word accesses under the privilege gates. Denied byte and
//                      half-word accesses are refused like word ones and leave the
//                      register untouched; a sub-word MDELEG write from below Machine
//                      mode is refused and changes no field, with RESP=1 (ERROR) and
//                      with RESP=0 (dropped).
//----------------------------------------------------------------------------

localparam REGOUT_00 = 32'h00400000;
localparam MDELEG    = 32'h00400040;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk);

      ahb_write(1, MACHINE,    REGOUT_00,             32'h11223344, 2, OK);

      // Reset gates (Machine only, RESP=1): narrow denied accesses -> ERROR.
      ahb_write(1, USER,       REGOUT_00 + 32'h1,     32'h000000AA, 0, ERROR);
      ahb_write(1, SUPERVISOR, REGOUT_00 + 32'h2,     32'h0000BBCC, 1, ERROR);
      ahb_read (1, USER,       REGOUT_00 + 32'h3,     32'h00000000, 0, 0, ERROR);
      ahb_read (1, SUPERVISOR, REGOUT_00,             32'h00000000, 1, 0, ERROR);
      ahb_read (1, MACHINE,    REGOUT_00,             32'h11223344, 2, 1, OK);

      // MDELEG is Machine-only whatever its gates say: sub-word writes from S/U
      // are refused. Open the gates first so only the MDELEG rule can refuse.
      ahb_write(1, MACHINE,    MDELEG,                32'h00000100, 2, OK);
      ahb_write(1, SUPERVISOR, MDELEG,                32'h000000FF, 0, ERROR);
      ahb_write(1, USER,       MDELEG + 32'h1,        32'h000000FF, 0, ERROR);
      ahb_read (1, MACHINE,    MDELEG,                32'h00000100, 2, 1, OK);

      // Same with RESP=0: dropped silently, nothing changes.
      ahb_write(1, MACHINE,    MDELEG,                32'h00000000, 2, OK);
      ahb_write(1, SUPERVISOR, MDELEG + 32'h1,        32'h000000FF, 0, OK);
      ahb_write(1, USER,       MDELEG,                32'h0000FFFF, 1, OK);
      ahb_read (1, MACHINE,    MDELEG,                32'h00000000, 2, 1, OK);

      // Machine-only gates, RESP=0: narrow denied data accesses dropped.
      ahb_write(1, MACHINE,    MDELEG,                32'h0000000F, 2, OK);
      ahb_write(1, USER,       REGOUT_00 + 32'h1,     32'h000000AA, 0, OK);
      ahb_read (1, USER,       REGOUT_00,             32'h00000000, 1, 1, OK);
      ahb_read (1, MACHINE,    REGOUT_00,             32'h11223344, 2, 1, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
