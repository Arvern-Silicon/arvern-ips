//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    jtag_pause_resume
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : jtag_pause_resume
// Module Description : A shift suspended in Pause-DR / Pause-IR must resume with the
//                      register contents intact.
//
//   Pause is how a debugger holds a partially-shifted register while it fetches more
//   data, and IEEE 1149.1 makes both Pause states mandatory. No BFM task navigated
//   there, so Pause-DR and Exit2-DR were never entered by any test -- coverage put them
//   at zero across the whole suite. Pause-IR/Exit2-IR were reached only incidentally,
//   by an async TRST landing the FSM there in dmi_reset_cross.
//
//   Both registers are shifted in two halves with a parked excursion in between. The
//   pause must be transparent: shifting IDCODE out across one is the check, since any
//   corruption or lost bit changes the value.
//----------------------------------------------------------------------------

// shift_dr with a Pause-DR excursion after `nfirst` bits.
task shift_dr_paused;
    input  [63:0]  tdi_dr;
    input  integer nbits;
    input  integer nfirst;
    input  integer npause;
    output [63:0]  tdo_dr;
    integer i;
    begin
        tdo_dr = 64'b0;
        tck_cycle(1'b1, 1'b0);                    // RTI   -> Select-DR
        tck_cycle(1'b0, 1'b0);                    //       -> Capture-DR
        tck_cycle(1'b0, 1'b0);                    //       -> Shift-DR
        for (i = 0; i < nfirst; i = i + 1) begin
            tck_cycle((i == nfirst-1) ? 1'b1 : 1'b0, tdi_dr[i]);   // last -> Exit1-DR
            tdo_dr[i] = tdo_sampled;
        end
        tck_cycle(1'b0, 1'b0);                    // Exit1 -> Pause-DR
        for (i = 0; i < npause; i = i + 1)
            tck_cycle(1'b0, 1'b0);                // parked
        tck_cycle(1'b1, 1'b0);                    // Pause -> Exit2-DR
        tck_cycle(1'b0, 1'b0);                    // Exit2 -> Shift-DR
        for (i = nfirst; i < nbits; i = i + 1) begin
            tck_cycle((i == nbits-1) ? 1'b1 : 1'b0, tdi_dr[i]);    // last -> Exit1-DR
            tdo_dr[i] = tdo_sampled;
        end
        tck_cycle(1'b1, 1'b0);                    // Exit1 -> Update-DR
        tck_cycle(1'b0, 1'b0);                    //       -> Run-Test/Idle
    end
endtask

// shift_ir with a Pause-IR excursion after `nfirst` bits.
task shift_ir_paused;
    input  [4:0]   ir_val;
    input  integer nfirst;
    input  integer npause;
    integer i;
    begin
        tck_cycle(1'b1, 1'b0);                    // RTI   -> Select-DR
        tck_cycle(1'b1, 1'b0);                    //       -> Select-IR
        tck_cycle(1'b0, 1'b0);                    //       -> Capture-IR
        tck_cycle(1'b0, 1'b0);                    //       -> Shift-IR
        for (i = 0; i < nfirst; i = i + 1)
            tck_cycle((i == nfirst-1) ? 1'b1 : 1'b0, ir_val[i]);   // last -> Exit1-IR
        tck_cycle(1'b0, 1'b0);                    // Exit1 -> Pause-IR
        for (i = 0; i < npause; i = i + 1)
            tck_cycle(1'b0, 1'b0);                // parked
        tck_cycle(1'b1, 1'b0);                    // Pause -> Exit2-IR
        tck_cycle(1'b0, 1'b0);                    // Exit2 -> Shift-IR
        for (i = nfirst; i < 5; i = i + 1)
            tck_cycle((i == 4) ? 1'b1 : 1'b0, ir_val[i]);          // last -> Exit1-IR
        tck_cycle(1'b1, 1'b0);                    // Exit1 -> Update-IR
        tck_cycle(1'b0, 1'b0);                    //       -> Run-Test/Idle
    end
endtask

initial
   begin : test
      reg [63:0] cap;
      reg [31:0] id;

      @(posedge dbgresetn);
      @(posedge trst_n);
      repeat (4) @(posedge tck);

      tap_reset;

      $display(" ===============================================");
      $display("|   Pause-DR: suspend and resume a DR shift     |");
      $display(" ===============================================");
      shift_ir(IR_IDCODE);
      shift_dr_paused(64'b0, 32, 16, 6, cap);
      check_eq("id_pause_dr", cap[31:0], DUT_IDCODE);

      $display(" ===============================================");
      $display("|   Pause-IR: suspend and resume an IR shift    |");
      $display(" ===============================================");
      // Shifting IR_IDCODE across the pause; a corrupted IR selects another register
      // and the read below returns something else.
      tap_reset;
      shift_ir_paused(IR_IDCODE, 2, 6);
      shift_dr(64'b0, 32, cap);
      check_eq("id_pause_ir", cap[31:0], DUT_IDCODE);

      // Normal navigation still works afterwards.
      tap_reset;
      idcode_read(id);
      check_eq("idcode_after", id, DUT_IDCODE);

      repeat (8) @(posedge tck);
      stimulus_done = 1'b1;
   end
