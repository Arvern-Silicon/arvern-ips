//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_busy_recover
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_busy_recover.v
// Module Description : DMI sticky-error semantics -- the heart of the DTM.
//
//   Part A (BUSY): stall the hclk-side response (slave_hold) so an op stays in
//   flight, then read the dmi register back too early. The captured op field
//   must report BUSY (3), the condition must be STICKY (further reads stay BUSY,
//   dtmcs.dmistat reports BUSY) even after the op actually completes, and only
//   dtmcs.dmireset must recover it -- after which the originally-read data is
//   returned with success.
//
//   Part B (FAILED): a failed response is equally sticky -- it persists, drops
//   intervening ops, and is cleared only by dmireset.
//
//   This test is why the bench runs TCK and hclk at a non-integer ratio with a
//   randomized phase: a CDC that only works at a convenient alignment would
//   pass a naive fixed-ratio bench but fail here.
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

      // Seed a known value at 0x10 with the slave running normally.
      slave_hold = 1'b0;
      dmi_write(7'h10, 32'hC0DE_1234, 8);

      $display(" ===============================================");
      $display("|   Part A: stall response -> BUSY + sticky     |");
      $display(" ===============================================");

      // Freeze the hclk-side response so the op cannot complete.
      slave_hold = 1'b1;
      dmi_scan(7'h10, 32'b0, OP_READ, rd, st);   // launch read, no settle

      // Read the dmi register back while still in flight -> must report BUSY.
      dmi_scan(7'h00, 32'b0, OP_NOP, rd, st);
      check_eq("busy1", st, OP_BUSY);

      // Sticky: a second readback still reports BUSY.
      dmi_scan(7'h00, 32'b0, OP_NOP, rd, st);
      check_eq("busy2", st, OP_BUSY);

      // dtmcs.dmistat must also report BUSY.
      dtmcs_read(dt);
      check_eq("dmistat_busy", dt[11:10], OP_BUSY);

      // Let the op actually complete, but the sticky condition must persist.
      slave_hold = 1'b0;
      idle_cycles(24);
      shift_ir(IR_DMI);
      dmi_scan(7'h00, 32'b0, OP_NOP, rd, st);
      check_eq("busy_sticky", st, OP_BUSY);

      $display(" ===============================================");
      $display("|   Part A: dmireset recovers, data intact      |");
      $display(" ===============================================");

      // Clear the sticky condition; the completed read's data must come back.
      dtmcs_write(32'h0001_0000);                 // dmireset = bit16
      shift_ir(IR_DMI);
      dmi_scan(7'h00, 32'b0, OP_NOP, rd, st);
      check_eq("recover_st", st, OP_SUCCESS);
      check_eq("recover_rd", rd, 32'hC0DE_1234);

      // A fresh transaction works normally after recovery.
      dmi_write(7'h11, 32'h0BAD_F00D, 8);
      dmi_read (7'h11, 8, rd, st);
      check_eq("post_st", st, OP_SUCCESS);
      check_eq("post_rd", rd, 32'h0BAD_F00D);

      $display(" ===============================================");
      $display("|   Part B: failed response is sticky too       |");
      $display(" ===============================================");

      // Seed a clean value at 0x40, then make 0x30 fault.
      dmi_write(7'h40, 32'h4444_4444, 8);
      slave_fault_en   = 1'b1;
      slave_fault_addr = 7'h30;

      dmi_read(7'h30, 8, rd, st);
      check_eq("failed", st, OP_FAILED);

      // While the failed-sticky is set, an intervening write must be DROPPED.
      dmi_write(7'h40, 32'hBEEF_BEEF, 8);

      // dtmcs.dmistat reports the sticky failed code.
      dtmcs_read(dt);
      check_eq("dmistat_failed", dt[11:10], OP_FAILED);

      // Recover and prove the dropped write never landed.
      dtmcs_write(32'h0001_0000);                 // dmireset
      slave_fault_en = 1'b0;
      shift_ir(IR_DMI);
      dmi_read(7'h40, 8, rd, st);
      check_eq("drop_st", st, OP_SUCCESS);
      check_eq("drop_rd", rd, 32'h4444_4444);     // NOT 0xBEEFBEEF

      repeat (8) @(posedge tck);
      stimulus_done = 1'b1;
   end
