//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    jtag_capture_exit
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : jtag_capture_exit
// Module Description : Capture -> Exit1 -> Update with no Shift, on the dmi and
//                      dtmcs DRs and on the IR: the register updates with the
//                      value it captured.
//
//   IEEE 1149.1 allows Capture-DR -> Exit1-DR (TMS = 1) -> Update-DR; with no shift
//   the update stage takes the captured value. doc/arv_dtm_jtag.md: "A DMI op is
//   launched at Update-DR when IR=dmi and op != nop. The result is collected on a
//   later scan: the Capture-DR value carries the address of the last launched op,
//   its data (read data) and its op status"; response op "0=success, 2=failed,
//   3=busy"; "While any sticky error is set, dmistat and the dmi op field report
//   it, and further DMI ops are dropped"; "after it [dmireset], the originally-
//   requested read's data is returned with success". dtmcs: "the two reset bits are
//   write-1 strobes at Update-DR" and read 0 (dtmcs_fields). IR: "Capture-IR loads
//   0b00001" -- IDCODE -- so an IR Capture -> Exit1 -> Update selects IDCODE.
//
//   dmi after a success: the captured op is 0 (nop), no transfer, the next capture
//   is unchanged. dmi with sticky failed: the captured op 2 is dropped, no transfer,
//   no subordinate word changes, dmistat stays 2. dmi while a read is held: the
//   capture latches busy, its op 3 is dropped, exactly one transfer, and dmireset
//   returns the held read's data. dtmcs, with a failure pending and with a transfer
//   held: no dmireset (dmistat / errinfo unchanged), no dmihardreset (PSEL held).
//   TDI is 1 on every Capture/Exit/Update cycle. Runs on JTAG and cJTAG.
//----------------------------------------------------------------------------

integer    ce_psel;
reg [31:0] ce_snap [0:127];
integer    ce_a;
integer    ce_bad;

initial ce_psel = 0;
always @(posedge dmi_psel) ce_psel = ce_psel + 1;

task ce_bit;
   input tms_val;
   input tdi_val;
   begin
`ifdef DTM_CJTAG
      cjtag_bit(tms_val, tdi_val);
`else
      tck_cycle(tms_val, tdi_val);
`endif
   end
endtask

// RTI -> Select-DR -> Capture-DR -> Exit1-DR -> Update-DR -> RTI
task ce_dr;
   begin
      ce_bit(1'b1, 1'b1);
      ce_bit(1'b0, 1'b1);
      ce_bit(1'b1, 1'b1);
      ce_bit(1'b1, 1'b1);
      ce_bit(1'b0, 1'b0);
   end
endtask

// RTI -> Select-DR -> Select-IR -> Capture-IR -> Exit1-IR -> Update-IR -> RTI
task ce_ir;
   begin
      ce_bit(1'b1, 1'b1);
      ce_bit(1'b1, 1'b1);
      ce_bit(1'b0, 1'b1);
      ce_bit(1'b1, 1'b1);
      ce_bit(1'b1, 1'b1);
      ce_bit(1'b0, 1'b0);
   end
endtask

task ce_snapshot;
   begin
      for (ce_a = 0; ce_a < 128; ce_a = ce_a + 1) ce_snap[ce_a] = slave_mem[ce_a];
   end
endtask

task ce_mem_intact;
   input [127:0] name;
   begin
      ce_bad = 0;
      for (ce_a = 0; ce_a < 128; ce_a = ce_a + 1)
         if (slave_mem[ce_a] !== ce_snap[ce_a]) ce_bad = ce_bad + 1;
      check_eq(name, ce_bad, 0);
   end
endtask

task ce_quiet;
   begin
      idle_cycles(DTM_IDLE_N);
      repeat (20) @(posedge free_clk);
   end
endtask

initial
   begin : test
      reg [63:0] cap;
      reg [63:0] cap2;
      reg [31:0] rd;
      reg  [1:0] st;
      reg [31:0] d0;
      reg  [1:0] s0;
      reg [31:0] dcs;
      integer    p0;

      dtm_init;                                   // TLR -> RTI, IR = DMI
      slave_latency = 1;
      for (ce_a = 0; ce_a < 128; ce_a = ce_a + 1) slave_mem[ce_a] = 32'h6C00_0000 + ce_a;

      $display(" ===================================================");
      $display("|  dmi: Capture -> Exit1 -> Update after a success  |");
      $display(" ===================================================");
      dmi_write(7'h15, 32'hA5A5_1234, DTM_IDLE_N);
      dmi_read(7'h15, DTM_IDLE_N, rd, st);
      check_eq("seed_rd", rd, 32'hA5A5_1234);
      check_eq("seed_st", st, OP_SUCCESS);
      shift_dr(64'b0, DMI_DR_W, cap);             // nop: the capture of the read
      check_eq("cap_addr", cap[DMI_DR_W-1:34], 7'h15);
      check_eq("cap_data", cap[33:2], 32'hA5A5_1234);
      check_eq("cap_op",   cap[1:0], OP_SUCCESS);
      ce_quiet;
      ce_snapshot;
      p0 = ce_psel;
      ce_dr;
      ce_quiet;
      check_eq("ok_no_psel", ce_psel - p0, 0);
      ce_mem_intact("ok_mem_intact");
      shift_dr(64'b0, DMI_DR_W, cap2);
      check_eq("ok_cap_same", cap2[DMI_DR_W-1:0], cap[DMI_DR_W-1:0]);
      dtm_dmi_write(7'h16, 32'h0F1E_2D3C, st);
      dtm_dmi_read (7'h16, rd, st);
      check_eq("ok_after_rd", rd, 32'h0F1E_2D3C);
      check_eq("ok_after_st", st, OP_SUCCESS);

      $display(" ===================================================");
      $display("|  dmi / dtmcs: Capture -> Exit1 -> Update, failed  |");
      $display(" ===================================================");
      slave_fault_en   = 1'b1;
      slave_fault_addr = 7'h20;
      dmi_read(7'h20, DTM_IDLE_N, rd, st);
      check_eq("fail_st", st, OP_FAILED);
      ce_quiet;
      ce_snapshot;
      p0 = ce_psel;
      ce_dr;                                      // captured op = 2: dropped while sticky
      ce_quiet;
      check_eq("fail_no_psel", ce_psel - p0, 0);
      ce_mem_intact("fail_mem_intact");
      dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, d0, s0);
      check_eq("fail_op_sticky", s0, OP_FAILED);
      dtmcs_read(dcs);
      check_eq("fail_dmistat", dcs[11:10], 2'd2);
      check_eq("fail_errinfo", dcs[20:18], 3'd3);

      ce_dr;                                      // IR = dtmcs: W1 bits captured as 0
      ce_quiet;
      dtmcs_read(dcs);
      check_eq("dtmcs_ce_dmistat", dcs[11:10], 2'd2);
      check_eq("dtmcs_ce_errinfo", dcs[20:18], 3'd3);
      check_eq("dtmcs_ce_no_psel", ce_psel - p0, 0);

      dtmcs_write(32'h0001_0000);                 // dmireset
      dtmcs_read(dcs);
      check_eq("rst_dmistat", dcs[11:10], 2'd0);
      check_eq("rst_errinfo", dcs[20:18], 3'd4);
      slave_fault_en = 1'b0;
      shift_ir(IR_DMI);
      dmi_read(7'h20, DTM_IDLE_N, rd, st);
      check_eq("fail_word_intact", rd, 32'h6C00_0020);
      check_eq("fail_word_st", st, OP_SUCCESS);

      $display(" ===================================================");
      $display("|  dmi / dtmcs: Capture -> Exit1 -> Update, busy    |");
      $display(" ===================================================");
      slave_mem[7'h33] = 32'h3333_C0DE;
      slave_hold = 1'b1;
      p0 = ce_psel;
      dmi_scan(7'h33, 32'b0, OP_READ, d0, s0);    // launch, held by the subordinate
      ce_dr;                                      // capture latches busy; op 3 dropped
      ce_quiet;
      check_eq("busy_one_psel", ce_psel - p0, 1);
      check_eq("busy_psel_held", {31'd0, dmi_psel}, 32'd1);
      shift_ir(IR_DTMCS);
      ce_dr;                                      // no dmihardreset strobe
      ce_quiet;
      check_eq("dtmcs_ce_psel_held", {31'd0, dmi_psel}, 32'd1);
      dtmcs_read(dcs);
      check_eq("busy_dmistat", dcs[11:10], 2'd3);
      slave_hold = 1'b0;
      repeat (40) @(posedge free_clk);
      check_eq("busy_done_one_psel", ce_psel - p0, 1);
      dtmcs_read(dcs);
      check_eq("busy_sticky_dmistat", dcs[11:10], 2'd3);
      dtmcs_write(32'h0001_0000);                 // dmireset
      shift_ir(IR_DMI);
      dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, rd, st);
      check_eq("busy_rd",  rd, 32'h3333_C0DE);
      check_eq("busy_st",  st, OP_SUCCESS);
      check_eq("busy_total_psel", ce_psel - p0, 1);

      $display(" ===================================================");
      $display("|  IR: Capture -> Exit1 -> Update selects IDCODE    |");
      $display(" ===================================================");
      ce_ir;                                      // from IR = DMI
      shift_dr(64'b0, 32, cap);
      check_eq("ir_from_dmi_idcode", cap[31:0], DUT_IDCODE);
      shift_ir(IR_DTMCS);
      ce_ir;
      shift_dr(64'b0, 32, cap);
      check_eq("ir_from_dtmcs_idcode", cap[31:0], DUT_IDCODE);
      shift_ir(IR_BYPASS);
      ce_ir;
      shift_dr(64'b0, 32, cap);
      check_eq("ir_from_bypass_idcode", cap[31:0], DUT_IDCODE);

      shift_ir(IR_DMI);
      p0 = ce_psel;
      dtm_dmi_write(7'h17, 32'h7777_1717, st);
      dtm_dmi_read (7'h17, rd, st);
      check_eq("final_rd", rd, 32'h7777_1717);
      check_eq("final_st", st, OP_SUCCESS);
      check_eq("final_psel", ce_psel - p0, 2);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
