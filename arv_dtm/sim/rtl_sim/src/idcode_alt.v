//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    idcode_alt
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : idcode_alt.v
// Module Description : IDCODE is honoured for ANY parameter value, not just the default.
//
//   idcode_bypass proves the DEFAULT IDCODE reads back. That value is
//   0x000001F7, whose top 23 bits are zero, so most of the IDCODE shift
//   register only ever carries zeros -- a stuck-at-0 bit anywhere above bit 8
//   would read back correctly and the test would still pass.
//
//   This test elaborates the same DUT with IDCODE = 0xAAAAAAAB (the bench
//   selects it on +define+IDCODE_ALT, injected by the runner for this test
//   name) and reads it back. The alternating pattern puts a 1 in every other
//   position and shifts a 1 through every position, so any bit of the DR that
//   is stuck, mis-ordered or unwired changes the captured word.
//
//   Bit 0 is deliberately 1: IEEE 1149.1 requires the IDCODE LSB to be 1, which
//   is how a debugger distinguishes IDCODE from BYPASS after Test-Logic-Reset.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] id;

      @(posedge dbgresetn);
      @(posedge trst_n);
      repeat (4) @(posedge tck);

      $display(" ===============================================");
      $display("|   IDCODE with a non-default parameter value   |");
      $display(" ===============================================");

      // Guard the premise: if the override did not reach the elaboration this
      // test silently degenerates into a duplicate of idcode_bypass.
      if (DUT_IDCODE == 32'h0000_01F7)
         begin
            $display("ERROR: IDCODE_ALT did not take effect -- DUT_IDCODE is still the default %t", $time);
            error = error + 1;
         end

      // IEEE 1149.1: the IDCODE LSB must be 1 whatever the value.
      check_eq("idcode_lsb", DUT_IDCODE[0], 1'b1);

      // Read after Test-Logic-Reset: the TAP loads IDCODE without an IR scan.
      tap_reset;
      idcode_read(id);
      check_eq("idcode_alt", id, DUT_IDCODE);

      // And again, to show the capture is repeatable rather than a one-shot.
      idcode_read(id);
      check_eq("idcode_alt2", id, DUT_IDCODE);

      repeat (8) @(posedge tck);
      stimulus_done = 1'b1;
   end
