//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_status_recover
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_status_recover.v
// Module Description : dmireset/dmihardreset must clear the *reported* DMI error
//                      status, not just the internal sticky flag.
//
//   Part A: after a failed op, dtmcs.dmireset must make BOTH dtmcs.dmistat and
//   the dmi op field read success(0) *before any new op* -- the completed op's
//   status must not leak a phantom failed(2) that stalls the spec recovery loop
//   "write dmireset, poll dmistat until 0".
//
//   Part B: dmihardreset of an in-flight op must not re-latch the stale failed
//   status from the previous (already-recovered) failure.
//
//   Distinct from dmi_busy_recover / dmi_hardreset: those re-read via a *new* op
//   (which overwrites the stale status) and never had a stale failed status, so
//   they cannot see this bug.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;
      reg [31:0] dt;

      @(posedge dbgresetn);
      @(posedge trst_n);
      repeat (4) @(posedge tck);

      tap_reset;
      shift_ir(IR_DMI);

      slave_hold = 1'b0;
      dmi_write(7'h40, 32'h4444_4444, 8);         // clean seed for later

      $display(" ===============================================");
      $display("|   Part A: dmireset clears the reported status |");
      $display(" ===============================================");

      // Take a genuine failure -> sticky failed + completed status = failed(2).
      slave_fault_en   = 1'b1;
      slave_fault_addr = 7'h30;
      dmi_read(7'h30, 8, rd, st);
      check_eq("failed", st, OP_FAILED);

      // Recover with dmireset; fault source removed; NO new DMI op issued yet.
      slave_fault_en = 1'b0;
      dtmcs_write(32'h0001_0000);                 // dmireset = bit16

      // dtmcs.dmistat must read success(0) -- not a stale failed(2).
      dtmcs_read(dt);
      check_eq("dmistat_clean", dt[11:10], OP_SUCCESS);

      // The dmi op field (poll readback, no new op) must read success(0) too.
      shift_ir(IR_DMI);
      dmi_scan(7'h00, 32'b0, OP_NOP, rd, st);
      check_eq("opfield_clean", st, OP_SUCCESS);

      $display(" ===============================================");
      $display("|   Part B: dmihardreset won't re-latch failed  |");
      $display(" ===============================================");

      // Reload a stale completed-failed status, then clear the sticky flag.
      slave_fault_en   = 1'b1;
      slave_fault_addr = 7'h30;
      shift_ir(IR_DMI);
      dmi_read(7'h30, 8, rd, st);
      check_eq("failedB", st, OP_FAILED);
      slave_fault_en = 1'b0;
      dtmcs_write(32'h0001_0000);                 // dmireset (dm_cstatus stays failed)

      // Launch a fresh op, hold it in flight, then abort it with dmihardreset.
      shift_ir(IR_DMI);
      slave_hold = 1'b1;
      dmi_scan(7'h40, 32'b0, OP_READ, rd, st);    // launch, stays in flight
      dtmcs_write(32'h0002_0000);                 // dmihardreset = bit17

      slave_abort = 1'b1;                          // slave drops the abandoned transfer
      repeat (2) @(posedge free_clk);
      slave_abort = 1'b0;
      slave_hold  = 1'b0;

      // The abort must NOT have re-latched sticky-failed from the stale status.
      shift_ir(IR_DMI);
      dmi_scan(7'h00, 32'b0, OP_NOP, rd, st);
      check_eq("opfield_clean2", st, OP_SUCCESS);
      dtmcs_read(dt);
      check_eq("dmistat_clean2", dt[11:10], OP_SUCCESS);

      // A fresh transaction works normally after recovery.
      shift_ir(IR_DMI);
      dmi_write(7'h41, 32'h0BAD_F00D, 8);
      dmi_read (7'h41, 8, rd, st);
      check_eq("post_st", st, OP_SUCCESS);
      check_eq("post_rd", rd, 32'h0BAD_F00D);

      repeat (8) @(posedge tck);
      stimulus_done = 1'b1;
   end
