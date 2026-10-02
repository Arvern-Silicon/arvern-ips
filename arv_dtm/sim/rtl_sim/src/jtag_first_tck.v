//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    jtag_first_tck
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : jtag_first_tck
// Module Description : Reaching Test-Logic-Reset takes exactly five TMS=1 clocks from
//                      the worst-case state -- not four, and not six.
//
//   IEEE 1149.1 guarantees five TMS=1 clocks force TLR from ANY state. The BFMs spend
//   exactly five in tap_reset: a defect that swallows one TAP clock at the start of a
//   sequence is invisible when the sequence has a clock to spare. `cjtag_first_packet`
//   guards the cJTAG case; this is the general guard.
//
//   Shift-DR is the worst case: Exit1-DR, Update-DR, Select-DR, Select-IR, TLR. The
//   four-clock check is the half that matters -- reaching TLR early would mean the TAP
//   resets on sequences that must not reset it.
//----------------------------------------------------------------------------

// tck_cycle returns ON the rising edge, where the state flop has not yet taken its new
// value -- sampling there reads the PREVIOUS state. Settle first (TCK half-period is
// 15.5 ns, so 1 ns is safely inside it and before the next edge).
task tap_state;
    output [3:0] st;
    begin
        #1 st = dut.g_jtag.u_dtm.u_tap.state;
    end
endtask

initial
   begin : test
      reg [31:0] id;
      reg [3:0]  st;
      integer    k;

      @(posedge dbgresetn);
      @(posedge trst_n);
      repeat (4) @(posedge tck);

      $display(" ===============================================");
      $display("|   TLR is exactly five TMS=1 from Shift-DR     |");
      $display(" ===============================================");

      tap_reset;
      shift_ir(IR_IDCODE);

      // Park in Shift-DR (IDCODE selected, so Update-DR below is harmless).
      tck_cycle(1'b1, 1'b0);                    // RTI -> Select-DR
      tck_cycle(1'b0, 1'b0);                    //     -> Capture-DR
      tck_cycle(1'b0, 1'b0);                    //     -> Shift-DR
      tap_state(st);
      check_eq("in_shf_dr", st, 4'h4);

      // Four is not enough: Exit1-DR, Update-DR, Select-DR, Select-IR.
      for (k = 0; k < 4; k = k + 1) tck_cycle(1'b1, 1'b0);
      tap_state(st);
      check_eq("sel_ir_after_4", st, 4'h9);

      // The fifth lands in TLR.
      tck_cycle(1'b1, 1'b0);
      tap_state(st);
      check_eq("tlr_after_5", st, 4'h0);

      // TLR must also have reloaded IDCODE into the IR.
      tck_cycle(1'b0, 1'b0);                    // TLR -> Run-Test/Idle
      idcode_read(id);
      check_eq("idcode_after_5", id, DUT_IDCODE);

      repeat (8) @(posedge tck);
      stimulus_done = 1'b1;
   end
