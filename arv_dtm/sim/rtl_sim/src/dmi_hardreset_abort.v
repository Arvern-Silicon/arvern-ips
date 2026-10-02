//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_hardreset_abort
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_hardreset_abort
// Module Description : dmihardreset must abandon the outstanding transaction on the
//                      BUS, not merely clear the TCK-side sticky state.
//
//   `dmi_hardreset` covers the TCK half (busy -> cleared -> success). It cannot cover
//   this half, because it pulses slave_abort (the slave drops the transfer): that returns the
//   slave to idle, and on the next cycle it re-latches the still-asserted PSEL/PENABLE
//   and retires the abandoned transfer harmlessly. The DTM's own abort is invisible
//   through that path -- removing it changes nothing observable.
//
//   So here slave_abort is deliberately NOT pulsed. The stall is held across the hardreset,
//   which leaves the abort as the only thing that can end the transfer, and the check
//   is at the APB pins: PSEL/PENABLE must drop, and the transfer must never complete
//   a PREADY handshake once the slave is released.
//----------------------------------------------------------------------------

reg watch_apb;
reg apb_completed;

initial begin
   watch_apb     = 1'b0;
   apb_completed = 1'b0;
end

// Windowed: gated so the legitimate post-hardreset traffic does not trip it.
always @(posedge free_clk)
   if (watch_apb && dmi_penable && dmi_pready) apb_completed <= 1'b1;

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;

      @(posedge dbgresetn);
      @(posedge trst_n);
      repeat (4) @(posedge tck);

      tap_reset;
      shift_ir(IR_DMI);

      slave_hold = 1'b0;
      dmi_write(7'h50, 32'h5050_5050, 8);

      $display(" ===============================================");
      $display("|  Abandon an in-flight transfer on the bus     |");
      $display(" ===============================================");

      // A READ, not a write: the slave model commits writes on PSEL & PENABLE, before
      // PREADY, so a stalled write has already landed and leaves nothing to observe.
      slave_hold = 1'b1;
      dmi_scan(7'h50, 32'b0, OP_READ, rd, st);
      dmi_scan(7'h00, 32'b0, OP_NOP,  rd, st);
      check_eq("busy", st, OP_BUSY);

      // Precondition, or the checks below pass vacuously: the transfer really is
      // parked mid-ACCESS on the bus.
      check_eq("apb_active", {dmi_psel, dmi_penable}, 2'b11);

      watch_apb = 1'b1;
      dtmcs_write(32'h0002_0000);                 // dmihardreset = bit17

      // TCK toggle -> 2FF sync -> edge detect -> state update.
      repeat (8) @(posedge free_clk);

      // Still stalled, so the abort is the only thing that can have ended it.
      check_eq("apb_dropped", {dmi_psel, dmi_penable}, 2'b00);

      // Released: the slave now completes into a deselected bus. With PENABLE low
      // there is no handshake, so the abandoned response is never delivered.
      slave_hold = 1'b0;
      repeat (20) @(posedge free_clk);
      check_eq("no_apb_ack", apb_completed, 1'b0);
      watch_apb = 1'b0;

      $display(" ===============================================");
      $display("|  Fresh transaction works, DM state intact     |");
      $display(" ===============================================");

      shift_ir(IR_DMI);
      dmi_scan(7'h00, 32'b0, OP_NOP, rd, st);
      check_eq("cleared", st, OP_SUCCESS);

      dmi_write(7'h51, 32'h0BADC0DE, 8);
      dmi_read (7'h51, 8, rd, st);
      check_eq("post_st", st, OP_SUCCESS);
      check_eq("post_rd", rd, 32'h0BADC0DE);

      dmi_read (7'h50, 8, rd, st);
      check_eq("seed_rd", rd, 32'h5050_5050);

      repeat (8) @(posedge tck);
      stimulus_done = 1'b1;
   end
