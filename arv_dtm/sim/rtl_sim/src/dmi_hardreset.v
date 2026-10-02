//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_hardreset
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_hardreset.v
// Module Description : dtmcs.dmihardreset must "forget" an outstanding DMI
//                      transaction -- it forces the hclk-side bus FSM back to
//                      idle and clears the sticky/inflight state, so a fresh
//                      transaction proceeds with no deadlock. (The TB also pulses
//                      slave_abort so the held slave drops the abandoned transfer
//                      instead of answering it late.)
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;
      integer    k;

      @(posedge dbgresetn);
      @(posedge trst_n);
      repeat (4) @(posedge tck);

      tap_reset;
      shift_ir(IR_DMI);

      // Seed a value, then stall an in-flight read.
      slave_hold = 1'b0;
      dmi_write(7'h50, 32'h5050_5050, 8);

      $display(" ===============================================");
      $display("|   Stall an op, confirm BUSY, then hardreset   |");
      $display(" ===============================================");

      slave_hold = 1'b1;
      dmi_scan(7'h50, 32'b0, OP_READ, rd, st);    // launch read, stays in flight
      dmi_scan(7'h00, 32'b0, OP_NOP, rd, st);
      check_eq("busy", st, OP_BUSY);

      // dtmhardreset: forget the outstanding transaction.
      dtmcs_write(32'h0002_0000);                 // dmihardreset = bit17

      // Model the DM being reset too: discard the abandoned response, release.
      slave_abort = 1'b1;
      repeat (2) @(posedge free_clk);
      slave_abort = 1'b0;
      slave_hold  = 1'b0;

      // Sticky must be cleared (no lingering BUSY).
      shift_ir(IR_DMI);
      dmi_scan(7'h00, 32'b0, OP_NOP, rd, st);
      check_eq("cleared", st, OP_SUCCESS);

      $display(" ===============================================");
      $display("|   Fresh transaction works after hardreset     |");
      $display(" ===============================================");

      dmi_write(7'h51, 32'h0BADC0DE, 8);
      dmi_read (7'h51, 8, rd, st);
      check_eq("post_st", st, OP_SUCCESS);
      check_eq("post_rd", rd, 32'h0BADC0DE);

      // And the original seed is still intact (hardreset didn't corrupt memory).
      dmi_read (7'h50, 8, rd, st);
      check_eq("seed_rd", rd, 32'h5050_5050);

      repeat (8) @(posedge tck);
      stimulus_done = 1'b1;
   end
