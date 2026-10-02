//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    idcode_bypass
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : idcode_bypass.v
// Module Description : TAP smoke test -- IDCODE read-out after Test-Logic-Reset
//                      (IR must auto-load IDCODE) and a BYPASS shift (1-bit DR,
//                      captures 0 then passes TDI through delayed by one TCK).
//----------------------------------------------------------------------------

// shift_ir, but capturing what the IR shifts OUT. Mirrors shift_dr's sampling.
task shift_ir_cap;
    input  [4:0] ir_val;
    output [4:0] cap_ir;
    integer i;
    begin
        cap_ir = 5'b0;
        tck_cycle(1'b1, 1'b0);      // RTI   -> Select-DR
        tck_cycle(1'b1, 1'b0);      //       -> Select-IR
        tck_cycle(1'b0, 1'b0);      //       -> Capture-IR
        tck_cycle(1'b0, 1'b0);      //       -> Shift-IR (IR SR holds the capture value)
        for (i = 0; i < 5; i = i + 1) begin
            tck_cycle((i == 4) ? 1'b1 : 1'b0, ir_val[i]);
            cap_ir[i] = tdo_sampled;
        end
        tck_cycle(1'b1, 1'b0);      // Exit1 -> Update-IR
        tck_cycle(1'b0, 1'b0);      //       -> Run-Test/Idle
    end
endtask

initial
   begin : test
      reg [31:0] id;
      reg [63:0] cap;
      reg [4:0]  icap;
      reg [7:0]  pat;
      reg [7:0]  exp;

      @(posedge dbgresetn);
      @(posedge trst_n);
      repeat (4) @(posedge tck);

      $display(" ===============================================");
      $display("|   IDCODE read after Test-Logic-Reset          |");
      $display(" ===============================================");
      tap_reset;
      idcode_read(id);
      check_eq("IDCODE", id, DUT_IDCODE);

      $display(" ===============================================");
      $display("|   BYPASS: 1-bit DR, TDI delayed by one TCK    |");
      $display(" ===============================================");
      shift_ir(IR_BYPASS);
      pat = 8'hB2;
      shift_dr({56'b0, pat}, 8, cap);
      // BYPASS captures 0, so out[i] = (i==0)?0:tdi[i-1]  => (pat<<1) & 0xFF
      exp = (pat << 1) & 8'hFF;
      check_eq("BYPASS", cap[7:0], exp);

      $display(" ===============================================");
      $display("|   Capture-IR loads ...01 (IEEE 1149.1 7.1.1)  |");
      $display(" ===============================================");
      // Mandatory, and a board-level scan tool relies on it to size the IR chain.
      // Nothing else in the suite reads the IR back, so the two LSBs were unverified.
      // Shifting IR_IDCODE back in keeps the TAP in a known state for the check below.
      shift_ir_cap(IR_IDCODE, icap);
      check_eq("cap_ir_lsbs", icap[1:0], 2'b01);

      // After TLR again, IDCODE must come back (proves IR reloaded IDCODE).
      tap_reset;
      idcode_read(id);
      check_eq("IDCODE2", id, DUT_IDCODE);

      repeat (8) @(posedge tck);
      stimulus_done = 1'b1;
   end
