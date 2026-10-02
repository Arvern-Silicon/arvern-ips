//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    cjtag_escape_inflight
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : cjtag_escape_inflight
// Module Description : An escape that takes the node Offline while a DMI read is
//                      held on the bus abandons it cleanly, and the link comes
//                      back with no phantom transfer and no stale status.
//
//   doc/arv_dtm_cjtag.md, Escapes: 4 or 5 changes = "deselection | node goes Offline,
//   TMSC released"; 8 or more = "reset | node goes Offline"; "Any escape other than a
//   custom one clears online, returning the TAP to Test-Logic-Reset."
//   doc/arv_dtm.md: "A TAP-only reset (JTAG trst_n_i, cJTAG going offline) abandons an
//   in-flight transfer the same way, on an hclk_i edge". Debug 1.0 Sec 6.1.4: errinfo
//   reset value 4 when implemented; doc/arv_dtm_jtag.md: dmistat 0 = none.
//
//   Part A: a read is held by the subordinate, a deselection escape (4 changes) takes
//   the node Offline, PSEL must drop; the node is re-activated and only THEN is the
//   subordinate released, so its orphan PREADY lands on a link that is back online.
//   Part B: the same with a very long reset escape (20 changes), the subordinate
//   released while the node is still Offline (the other release order).
//   Part C: a 20-change escape on an idle link; it must still attach.
//   After each: IDCODE reads back, dtmcs shows dmistat = 0 and errinfo = 4, a nop
//   poll reports op = 0, and a fresh write + read round-trips. dmi_psel rises are
//   counted from before the escape to the end of the part: exactly the two
//   transfers the host launches, nothing else (a phantom launched by the Offline
//   transition or the re-activation would add one).
//----------------------------------------------------------------------------

reg     ei_watch;
integer ei_rise;

initial begin
   ei_watch = 1'b0;
   ei_rise  = 0;
end

always @(posedge dmi_psel) if (ei_watch) ei_rise = ei_rise + 1;

// Link back: IDCODE, clean dtmcs, clean poll, no phantom, then a round trip.
task ei_check_link;
   input [6:0]  addr;
   input [31:0] val;
   reg [31:0] id;
   reg [31:0] dt;
   reg [31:0] rd;
   reg  [1:0] st;
   begin
      idcode_read(id);
      check_eq("idcode", id, DUT_IDCODE);
      dtmcs_read(dt);
      check_eq("dmistat", {30'd0, dt[11:10]}, 32'd0);
      check_eq("errinfo", {29'd0, dt[20:18]}, 32'd4);
      shift_ir(IR_DMI);
      dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, rd, st);
      check_eq("poll_op", st, OP_SUCCESS);
      check_eq("no_phantom", ei_rise, 0);

      dmi_write(addr, val, DTM_IDLE_N);
      dmi_read (addr, DTM_IDLE_N, rd, st);
      check_eq("rt_op",   st, OP_SUCCESS);
      check_eq("rt_data", rd, val);
      repeat (20) @(posedge free_clk);
      ei_watch = 1'b0;
      check_eq("psel_count", ei_rise, 2);
   end
endtask

task ei_launch_held;
   input [6:0] addr;
   reg [31:0] d0;
   reg  [1:0] s0;
   begin
      slave_hold = 1'b1;
      shift_ir(IR_DMI);
      dmi_scan(addr, 32'b0, OP_READ, d0, s0);
      idle_cycles(4);
      check_eq("apb_held", {dmi_psel, dmi_penable}, 2'b11);
   end
endtask

initial
   begin : test
      dtm_init;                                   // activate, TLR -> RTI, IR = DMI
      slave_latency = 1;
      slave_mem[7'h28] = 32'hA0A0_0028;
      slave_mem[7'h2A] = 32'hB0B0_002A;

      $display(" ===============================================");
      $display("|  A: deselection escape, read in flight        |");
      $display(" ===============================================");
      ei_launch_held(7'h28);
      ei_rise  = 0;
      ei_watch = 1'b1;
      cjtag_escape_n(4);                          // deselection -> Offline
      repeat (20) @(posedge free_clk);
      check_eq("A_psel_drop", {dmi_psel, dmi_penable}, 2'b00);

      cjtag_active_done = 1'b0;
      tap_reset;                                  // re-activate, TLR -> RTI
      slave_hold = 1'b0;                          // orphan PREADY onto the live link
      repeat (20) @(posedge free_clk);
      tap_reset;
      ei_check_link(7'h29, 32'h1111_A029);

      $display(" ===============================================");
      $display("|  B: 20-change reset escape, read in flight    |");
      $display(" ===============================================");
      ei_launch_held(7'h2A);
      ei_rise  = 0;
      ei_watch = 1'b1;
      cjtag_escape_n(20);                         // reset escape, far past 8
      repeat (20) @(posedge free_clk);
      check_eq("B_psel_drop", {dmi_psel, dmi_penable}, 2'b00);
      slave_hold = 1'b0;                          // orphan PREADY while Offline
      repeat (20) @(posedge free_clk);

      cjtag_active_done = 1'b0;
      tap_reset;
      ei_check_link(7'h2B, 32'h2222_B02B);

      $display(" ===============================================");
      $display("|  C: 20-change reset escape, idle link         |");
      $display(" ===============================================");
      ei_rise  = 0;
      ei_watch = 1'b1;
      cjtag_escape_n(20);
      repeat (20) @(posedge free_clk);
      cjtag_active_done = 1'b0;
      tap_reset;
      ei_check_link(7'h2C, 32'h3333_C02C);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
