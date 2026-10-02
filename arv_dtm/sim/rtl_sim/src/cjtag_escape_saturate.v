//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    cjtag_escape_saturate
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : cjtag_escape_saturate
// Module Description : Very long reset escapes (34, 40, 66 TMSC changes) with a DMI
//                      read held on the bus and a sticky busy latched, followed at
//                      once by a selection escape + activation.
//
//   doc/arv_dtm_cjtag.md, Escapes (Table 10-9 row): "8 or more | reset | node goes
//   Offline, TMSC released from the 8th change"; "the open-ended >= 8 compare is
//   right"; "Any escape other than a custom one clears online, returning the TAP to
//   Test-Logic-Reset." 2 or 3 changes are "custom ... no-op".
//   A change counter that wraps instead of saturating would decode 34 and 66 (and
//   40 at a 3-bit width) as 2 = custom no-op and leave the node Online.
//   doc/arv_dtm.md: "A TAP-only reset (JTAG trst_n_i, cJTAG going offline) abandons
//   an in-flight transfer the same way, on an hclk_i edge".
//   doc/arv_dtm_cjtag.md, Reset architecture: "tap_rst_n = dbgresetn_i & online" --
//   going Offline resets the TAP, sticky error included; Verification table,
//   cjtag_escape_inflight: "dmistat 0 / errinfo 4, and a fresh round trip".
//   doc/arv_dtm_jtag.md: dmistat "0 none, 2 failed, 3 busy"; errinfo "4 = unknown
//   (reset / no error)".
//   doc/arv_dtm_cjtag.md, Activation: "A selection escape frames the Selection
//   Sequence ... the bit right after the escape [is] OAC[0]".
//
//   Per escape length:
//     - a read is held by the subordinate and collected too early: op = busy and
//       dtmcs.dmistat = 3 (sticky) before the escape;
//     - the reset escape: PSEL/PENABLE drop, online = 0;
//     - IMMEDIATELY a selection escape + short activation (no TCKC edge in
//       between): online = 1;
//     - the subordinate is released (its orphan PREADY lands on an idle master) and
//       returns to idle;
//     - IDCODE, dmistat = 0, errinfo = 4, a nop poll reports op = 0, no phantom
//       transfer, then a fresh write + read round trip; exactly those two PSEL rises
//       from the escape to the end of the leg.
//----------------------------------------------------------------------------

reg     es_watch;
integer es_rise;

initial begin
   es_watch = 1'b0;
   es_rise  = 0;
end

always @(posedge dmi_psel) if (es_watch) es_rise = es_rise + 1;

task es_leg;
   input integer     nchg;
   input [ABITS-1:0] held_addr;
   input [ABITS-1:0] rt_addr;
   input [31:0]      rt_val;
   reg [31:0] d0;
   reg  [1:0] s0;
   reg [31:0] rd;
   reg  [1:0] st;
   reg [31:0] dt;
   reg [31:0] id;
   begin
      $display(" --- reset escape of %0d TMSC changes ---", nchg);
      // Held read, collected too early -> sticky busy.
      slave_hold = 1'b1;
      shift_ir(IR_DMI);
      dmi_scan(held_addr, 32'b0, OP_READ, d0, s0);
      idle_cycles(4);
      check_eq("held_on_bus", {dmi_psel, dmi_penable}, 2'b11);
      dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, rd, st);
      check_eq("pre_busy", st, OP_BUSY);
      dtmcs_read(dt);
      check_eq("pre_dmistat", {30'd0, dt[11:10]}, 32'd3);
      check_eq("pre_online", dut.g_cjtag.u_dtm.online, 1'b1);

      es_rise  = 0;
      es_watch = 1'b1;
      cjtag_escape_n(nchg);                              // reset escape
      repeat (4) @(posedge free_clk);
      check_eq("esc_offline", dut.g_cjtag.u_dtm.online, 1'b0);
      check_eq("esc_psel_drop", {dmi_psel, dmi_penable}, 2'b00);

      cjtag_activate;                                     // immediately: selection + code
      cjtag_active_done = 1'b1;
      check_eq("reactivated", dut.g_cjtag.u_dtm.online, 1'b1);
      check_eq("still_dropped", {dmi_psel, dmi_penable}, 2'b00);

      slave_hold = 1'b0;                                  // orphan PREADY, master idle
      repeat (20) @(posedge free_clk);

      tap_reset;                                          // already online: TLR -> RTI
      idcode_read(id);
      check_eq("idcode", id, DUT_IDCODE);
      dtmcs_read(dt);
      check_eq("dmistat", {30'd0, dt[11:10]}, 32'd0);
      check_eq("errinfo", {29'd0, dt[20:18]}, 32'd4);
      shift_ir(IR_DMI);
      dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, rd, st);
      check_eq("poll_op", st, OP_SUCCESS);
      check_eq("no_phantom", es_rise, 0);

      dmi_write(rt_addr, rt_val, DTM_IDLE_N);
      dmi_read (rt_addr, DTM_IDLE_N, rd, st);
      check_eq("rt_op",   st, OP_SUCCESS);
      check_eq("rt_data", rd, rt_val);
      dmi_read (held_addr, DTM_IDLE_N, rd, st);           // the abandoned read's register
      check_eq("held_op",   st, OP_SUCCESS);
      check_eq("held_data", rd, slave_mem[held_addr]);
      repeat (20) @(posedge free_clk);
      es_watch = 1'b0;
      check_eq("psel_count", es_rise, 3);
   end
endtask

initial
   begin : test
      dtm_init;                                           // activate, TLR -> RTI, IR = DMI
      slave_latency = 1;
      slave_mem[7'h31] = 32'hC1C1_0031;
      slave_mem[7'h33] = 32'hC3C3_0033;
      slave_mem[7'h35] = 32'hC5C5_0035;

      $display(" ===============================================");
      $display("|  40 / 34 / 66-change reset escape in flight   |");
      $display(" ===============================================");
      es_leg(40, 7'h31, 7'h32, 32'h4040_0032);
      es_leg(34, 7'h33, 7'h34, 32'h3434_0034);
      es_leg(66, 7'h35, 7'h36, 32'h6666_0036);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
