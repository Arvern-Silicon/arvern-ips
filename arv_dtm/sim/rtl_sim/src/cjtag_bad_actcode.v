//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    cjtag_bad_actcode
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : cjtag_bad_actcode
// Module Description : An activation code we do not implement must leave the node
//                      OFFLINE -- and must not wedge it.
//
//   Rule 11.9.5.2 b) makes a mismatched selection test fail, leaving the node Offline.
//   `code_ok` enforces three separate conditions, so all three are driven here:
//     OAC   != 0011   -> wrong technology/topology
//     STATE != 00     -> a parking state this node does not implement
//     PROTECT = 1     -> demands Voting Drive (Cl. 13.2.1.3), which we do not do
//
//   Every other cJTAG test drives a VALID code, so nothing before this one could tell
//   a real activation from a decoder that accepts anything. The closing check matters
//   as much as the rejections: a node that refuses a bad code must still activate on
//   the next good one, not latch itself out of service.
//----------------------------------------------------------------------------

// 12-bit activation code, LSB-first on the wire. The first 8 bits land as
// act_next[7:4] = OAC and act_next[3:0] = EC.
task cjtag_send_code12;
    input [11:0] seq;
    integer i;
    begin
        for (i = 0; i < 12; i = i + 1) cjtag_act_bit(seq[i]);
    end
endtask

initial
   begin : test
      reg [31:0] id;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|  cJTAG: a bad activation code stays OFFLINE   |");
      $display(" ===============================================");

      // -- wrong OAC (0001, not 0011): not our technology/topology --------------
      cjtag_escape_sel;
      cjtag_send_code12(12'h088);
      check_eq("offline_bad_oac", dut.g_cjtag.u_dtm.online, 1'b0);

      // -- OAC good, STATE != 00: a parking state we do not implement -----------
      cjtag_escape_sel;
      cjtag_send_code12(12'h09C);
      check_eq("offline_bad_state", dut.g_cjtag.u_dtm.online, 1'b0);

      // -- OAC good, PROTECT = 1: demands Voting Drive ---------------------------
      cjtag_escape_sel;
      cjtag_send_code12(12'h0CC);
      check_eq("offline_protect", dut.g_cjtag.u_dtm.online, 1'b0);

      // -- and the link is still usable: a good code activates --------------------
      cjtag_escape_sel;
      cjtag_send_actcode;
      check_eq("online_after_rejects", dut.g_cjtag.u_dtm.online, 1'b1);

      tap_reset;
      idcode_read(id);
      check_eq("idcode_after_rejects", id, DUT_IDCODE);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
