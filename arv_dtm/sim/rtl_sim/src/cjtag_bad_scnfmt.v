//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    cjtag_bad_scnfmt
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : cjtag_bad_scnfmt
// Module Description : A long-form activation selecting a scan format we do not
//                      implement must leave the node OFFLINE.
//
//   The long form carries a 24-bit Global Register State (Tbl 11-4) whose SCNFMT
//   field (bits 23:19) picks the scan format; only 9 = OScan1 (Cl. 23.4.1.4.5) is
//   implemented here. `cjtag_act_long` proves the correct value activates -- nothing
//   proved a wrong one is refused, so a decoder that ignored SCNFMT entirely looked
//   identical.
//
//   SCNFMT arrives ascending, its own LSB first, so bit19 is the LSB of the field.
//   Sending bit19 = 0 makes SCNFMT = 8 instead of 9: one bit from a valid sequence.
//----------------------------------------------------------------------------

// Long-form tail with a caller-chosen SCNFMT LSB, then the Check Packet.
// Mirrors cjtag_send_actcode_long_part2, which hardcodes scnfmt_lsb = 1.
task cjtag_send_grl_tail;
    input scnfmt_lsb;
    integer i;
    begin
        for (i = 0; i < 7; i = i + 1) cjtag_act_bit(1'b0);   // GRL bits 12..18
        cjtag_act_bit(scnfmt_lsb);                           // bit19 = SCNFMT LSB
        cjtag_act_bit(1'b0);                                 // bit20
        cjtag_act_bit(1'b0);                                 // bit21
        cjtag_act_bit(1'b1);                                 // bit22
        cjtag_act_bit(1'b0);                                 // bit23
        cjtag_act_bit(1'b0);                                 // CP Preamble
        cjtag_act_bit(1'b0);  cjtag_act_bit(1'b0);           // CP_END
        cjtag_act_bit(1'b0);                                 // CP Postamble
    end
endtask

initial
   begin : test
      reg [31:0] id;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|  cJTAG: long form with SCNFMT != 9 -> OFFLINE |");
      $display(" ===============================================");

      // -- SCNFMT = 8: a format we do not implement -----------------------------
      cjtag_escape_sel;
      cjtag_send_actcode_long_part1;
      cjtag_send_grl_tail(1'b0);
      check_eq("offline_scnfmt_8", dut.g_cjtag.u_dtm.online, 1'b0);

      // -- SCNFMT = 9 on the same path: activates -------------------------------
      // Same stimulus but for one bit, so a pass here means SCNFMT is genuinely
      // decoded rather than the long form being rejected wholesale.
      cjtag_escape_sel;
      cjtag_send_actcode_long_part1;
      cjtag_send_grl_tail(1'b1);
      check_eq("online_scnfmt_9", dut.g_cjtag.u_dtm.online, 1'b1);

      tap_reset;
      idcode_read(id);
      check_eq("idcode_scnfmt_9", id, DUT_IDCODE);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
