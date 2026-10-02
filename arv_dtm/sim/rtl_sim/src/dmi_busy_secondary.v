//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_busy_secondary
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_busy_secondary.v
// Module Description : SECONDARY busy -- a real op requested while one is in flight.
//
//   dmi_busy_recover already covers the case where the debugger reads the dmi
//   register back too early: those readbacks carry op=NOP, so they only OBSERVE
//   the in-flight state. This covers the other half -- issuing a REAL op (a
//   write) at Update-DR while the previous one is still in flight on hclk.
//   That is the only path that sets the sticky error from the TAP side:
//
//       if (dmi_op_active & dm_inflight & (sticky_err == 2'd0))
//           sticky_err_nxt = OP_BUSY;                  (arv_dtm_tap.v:364)
//
//   dmi_op_active is false for a NOP, so no amount of polling reaches it.
//
//   Beyond setting the sticky code, the rejected op must be DROPPED, never
//   queued: the seeded value has to survive untouched. That is the check that
//   would fail if a future change let the second op through.
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

      // Seed a known value with the slave running normally.
      slave_hold = 1'b0;
      dmi_write(7'h10, 32'hC0DE_1234, 8);

      $display(" ===============================================");
      $display("|  Real op while one is in flight -> BUSY       |");
      $display(" ===============================================");

      // Freeze the hclk-side response so op 1 cannot complete.
      slave_hold = 1'b1;
      dmi_scan(7'h10, 32'b0, OP_READ, rd, st);    // op 1: in flight, no settle

      // Op 2, a REAL write, while op 1 is still in flight. This is the
      // Update-DR that must set the sticky BUSY -- and it must not be performed.
      dmi_scan(7'h10, 32'hBAD0_BAD0, OP_WRITE, rd, st);

      // Poll: the sticky code is now visible.
      dmi_scan(7'h00, 32'b0, OP_NOP, rd, st);
      check_eq("secondary_busy", st, OP_BUSY);

      // dtmcs.dmistat agrees.
      dtmcs_read(dt);
      check_eq("dmistat_busy", dt[11:10], OP_BUSY);

      // Let op 1 finish. The sticky condition must survive its completion.
      slave_hold = 1'b0;
      idle_cycles(24);
      shift_ir(IR_DMI);
      dmi_scan(7'h00, 32'b0, OP_NOP, rd, st);
      check_eq("busy_sticky", st, OP_BUSY);

      $display(" ===============================================");
      $display("|  Rejected op was dropped, not queued         |");
      $display(" ===============================================");

      // Clear the sticky condition and prove the rejected write never landed.
      dtmcs_write(32'h0001_0000);                 // dmireset = bit16
      shift_ir(IR_DMI);
      dmi_read(7'h10, 8, rd, st);
      check_eq("drop_st", st, OP_SUCCESS);
      check_eq("drop_rd", rd, 32'hC0DE_1234);     // NOT 0xBAD0BAD0

      repeat (8) @(posedge tck);
      stimulus_done = 1'b1;
   end
