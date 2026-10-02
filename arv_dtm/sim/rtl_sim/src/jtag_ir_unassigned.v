//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    jtag_ir_unassigned
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : jtag_ir_unassigned
// Module Description : Every IR opcode other than IDCODE / DTMCS / DMI selects the
//                      1-bit BYPASS register; Capture-IR loads 0b00001 on every IR
//                      scan; the assigned registers still work afterwards.
//
//   doc/arv_dtm_jtag.md, Instruction register: "5 bits, reset value 0x01 (IDCODE).
//   Capture-IR loads 0b00001 (LSBs 01 per IEEE 1149.1)." Opcode table:
//   "BYPASS | 0x1f (and every other unassigned opcode) | 1-bit bypass".
//   Debug 1.0 Sec 6.1.2: "Unimplemented instructions must select the BYPASS
//   register." Table 16: 0x00 "bypass", 0x12..0x17 "reserved (bypass)", 0x1f
//   "bypass". Sec 6.1.6: BYPASS is a "1-bit register that has no effect", reset
//   value 0 (the register diagram) -- so the first bit out of a BYPASS scan is 0.
//
//   For each of the 29 opcodes 0x00, 0x02..0x0F, 0x12..0x1F:
//     - the IR scan shifts out 0b00001 (the Capture-IR value);
//     - a 41-bit DR scan returns the input delayed by exactly one bit behind a
//       leading 0 (1-bit DR). The pattern starts with bit 0 = 1 on the way out of
//       IDCODE/dtmcs (both have bit 0 = 1), so a mis-decode to either is caught on
//       the first bit; a mis-decode to dmi would return its 41-bit capture
//       instead of the delayed pattern.
//   The pattern's low two bits are 01 (read): a mis-decode to dmi would launch a
//   DMI op at Update-DR, so PSEL must not rise during the whole sweep.
//   Afterwards: IDCODE reads the parameter value, dtmcs its static fields with
//   dmistat 0, and a DMI write + read round-trips.
//----------------------------------------------------------------------------

reg     iu_watch;
integer iu_rise;

initial begin
   iu_watch = 1'b0;
   iu_rise  = 0;
end

always @(posedge dmi_psel) if (iu_watch) iu_rise = iu_rise + 1;

// shift_ir, also returning what the IR shifts out (the Capture-IR value).
task iu_shift_ir_cap;
   input  [4:0] ir_val;
   output [4:0] cap_ir;
   integer i;
   begin
      cap_ir = 5'b0;
      tck_cycle(1'b1, 1'b0);      // RTI   -> Select-DR
      tck_cycle(1'b1, 1'b0);      //       -> Select-IR
      tck_cycle(1'b0, 1'b0);      //       -> Capture-IR
      tck_cycle(1'b0, 1'b0);      //       -> Shift-IR
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
      reg  [4:0] op;
      reg  [4:0] icap;
      reg [63:0] pat;
      reg [63:0] cap;
      reg [63:0] exp;
      reg [31:0] id;
      reg [31:0] dt;
      reg [31:0] rd;
      reg  [1:0] st;
      integer    k;
      integer    nop;

      @(posedge dbgresetn);
      @(posedge trst_n);
      repeat (4) @(posedge tck);
      tap_reset;

      $display(" ===============================================");
      $display("|  Unassigned IR opcodes select BYPASS          |");
      $display(" ===============================================");
      pat = 64'h0000_00A5_C3E1_7B2D;                      // bits [1:0] = 01
      exp = {23'b0, pat[39:0], 1'b0};
      nop = 0;
      iu_rise  = 0;
      iu_watch = 1'b1;
      for (k = 0; k < 32; k = k + 1) begin
         op = k;
         if ((op != IR_IDCODE) && (op != IR_DTMCS) && (op != IR_DMI)) begin
            $display("opcode 0x%02h", op);
            iu_shift_ir_cap(op, icap);
            check_eq("capture_ir", icap, 5'b00001);
            shift_dr(pat, 41, cap);
            check_eq("bypass_dr", cap[40:0], exp[40:0]);
            nop = nop + 1;
         end
      end
      check_eq("opcodes_swept", nop, 29);
      repeat (20) @(posedge free_clk);
      iu_watch = 1'b0;
      check_eq("no_dmi_launch", iu_rise, 0);

      $display(" ===============================================");
      $display("|  Assigned registers still work                |");
      $display(" ===============================================");
      iu_shift_ir_cap(IR_IDCODE, icap);
      check_eq("capture_ir_id", icap, 5'b00001);
      shift_dr(64'b0, 32, cap);
      check_eq("idcode", cap[31:0], DUT_IDCODE);

      dtmcs_read(dt);
      check_eq("dtmcs_version", {28'd0, dt[3:0]},   32'd1);
      check_eq("dtmcs_abits",   {26'd0, dt[9:4]},   32'd7);
      check_eq("dtmcs_dmistat", {30'd0, dt[11:10]}, 32'd0);
      check_eq("dtmcs_idle",    {29'd0, dt[14:12]}, {29'd0, DUT_IDLE});
      check_eq("dtmcs_errinfo", {29'd0, dt[20:18]}, 32'd4);

      shift_ir(IR_DMI);
      dtm_dmi_write(7'h1E, 32'hB1A5_001E, st);
      dtm_dmi_read (7'h1E, rd, st);
      check_eq("dmi_op",   st, OP_SUCCESS);
      check_eq("dmi_data", rd, 32'hB1A5_001E);

      // An unassigned opcode after DMI traffic: still BYPASS, no launch.
      iu_rise  = 0;
      iu_watch = 1'b1;
      iu_shift_ir_cap(5'h12, icap);
      check_eq("capture_ir_12", icap, 5'b00001);
      shift_dr(pat, 41, cap);
      check_eq("bypass_dr_12", cap[40:0], exp[40:0]);
      repeat (20) @(posedge free_clk);
      iu_watch = 1'b0;
      check_eq("no_dmi_launch2", iu_rise, 0);

      // Test-Logic-Reset reloads IDCODE.
      tap_reset;
      shift_dr(64'b0, 32, cap);
      check_eq("idcode_tlr", cap[31:0], DUT_IDCODE);

      repeat (8) @(posedge tck);
      stimulus_done = 1'b1;
   end
