//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    size_check
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : size_check
// Module Description : Non-word (byte / half-word) accesses must be denied with
//                      an AHB ERROR -- dph_size_ok = (dph_size == 3'b010)
//                      (ahb_plic.v:238). Every existing test uses word accesses
//                      only, so the size-denial path was never stimulated; in
//                      the priv_off config the size check is the SOLE denial
//                      mechanism. A too-permissive size decode would be
//                      invisible. Valid word access is checked as the control.
//----------------------------------------------------------------------------

`define PLIC_BASE  32'h00400000
`define PRIO_BASE  32'h00000000

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|     PLIC : NON-WORD ACCESS -> AHB ERROR       |");
      $display(" ===============================================");

      // Control: a word write/read to priority[1] succeeds.
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*1, 32'd3, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*1, 32'd3, 2, 1, OK);

      // Byte and half-word accesses to the SAME valid register must ERROR.
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*1, 32'd1, 0, ERROR); // byte write
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*1, 32'd1, 1, ERROR); // half-word write
      ahb_read (1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*1, 32'd0, 0, 0, ERROR); // byte read
      ahb_read (1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*1, 32'd0, 1, 0, ERROR); // half-word read
      $display("PASS:  byte/half-word accesses denied with ERROR %t ns", $time);

      // The denied sub-word writes must not have corrupted the register.
      ahb_read (1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*1, 32'd3, 2, 1, OK);
      $display("PASS:  register value unchanged by denied sub-word writes %t ns", $time);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
