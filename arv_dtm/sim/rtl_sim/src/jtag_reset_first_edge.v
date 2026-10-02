//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    jtag_reset_first_edge
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : jtag_reset_first_edge
// Module Description : The first TCK edges after a trst_n_i or dbgresetn_i release
//                      behave as documented: the standard opening always works, and
//                      exactly two edges are swallowed, no more.
//
//   doc/arv_dtm_jtag.md, Integration requirements, Reset: "The TAP ignores the first
//   two TCK rising edges after trst_n_i or dbgresetn_i releases (the reset
//   synchroniser); open with TMS = 1 for at least five TCKs, as every debugger does,
//   rather than a scan straight after the release." IEEE 1149.1: the reset selects
//   IDCODE in the IR.
//
//   Before every pulse the TAP is left in Run-Test/Idle with IR = dtmcs.
//   Part A (trst_n) and C (dbgresetn): the documented opening -- 5 x TMS = 1, then
//   TMS = 0 -- right after the release, swept over several release phases against
//   TCK, then an IDCODE read: the documented opening works whatever the phase.
//   Part B (trst_n) and D (dbgresetn): the release is placed in a TCK low phase so
//   the next rising edge is unambiguously edge 1. Exactly two leading clocks with
//   every TMS pair (00, 01, 10, 11), then TMS 0,1,0,0 (Run-Test/Idle, Select-DR,
//   Capture-DR, Shift-DR) and 32 shifted bits must return IDCODE. The pair 01 fails
//   if either leading edge is honoured; the 0,1,0,0 suffix fails if a third edge is
//   swallowed. No IR scan precedes the 32 bits, so IDCODE there also proves the
//   reset reloaded the IR. dbgresetn is released synchronously to clk, as the doc
//   requires.
//----------------------------------------------------------------------------

integer rf_i;
integer rf_ph;

// Leave the TAP away from its reset state: Run-Test/Idle, IR = dtmcs.
task rf_park;
   begin
      tap_reset;
      shift_ir(IR_DTMCS);
   end
endtask

// TMS 0,1,0,0 into Shift-DR, then 32 bits out; the TAP must be in TLR.
task rf_scan_from_tlr;
   output [31:0] val;
   integer i;
   begin
      tck_cycle(1'b0, 1'b0);                     // TLR       -> Run-Test/Idle
      tck_cycle(1'b1, 1'b0);                     //           -> Select-DR
      tck_cycle(1'b0, 1'b0);                     //           -> Capture-DR
      tck_cycle(1'b0, 1'b0);                     //           -> Shift-DR
      for (i = 0; i < 32; i = i + 1) begin
         tck_cycle((i == 31) ? 1'b1 : 1'b0, 1'b0);
         val[i] = tdo_sampled;
      end
      tck_cycle(1'b1, 1'b0);                     // Exit1     -> Update-DR
      tck_cycle(1'b0, 1'b0);                     //           -> Run-Test/Idle
   end
endtask

initial
   begin : test
      reg [31:0] id;
      reg  [1:0] lead;

      @(posedge dbgresetn);
      @(posedge trst_n);
      repeat (4) @(posedge tck);

      $display(" ===============================================");
      $display("|  A: trst_n, documented opening, any phase     |");
      $display(" ===============================================");
      for (rf_ph = 0; rf_ph < 31; rf_ph = rf_ph + 3) begin
         rf_park;
         @(negedge tck);
         tms    = 1'b1;
         trst_n = 1'b0;
         repeat (2) @(posedge tck);
         @(negedge tck);
         #(rf_ph);
         trst_n = 1'b1;
         tap_reset;                                // 5 x TMS=1, TMS=0
         idcode_read(id);
         check_eq("A_idcode", id, DUT_IDCODE);
      end

      $display(" ===============================================");
      $display("|  B: trst_n, two leading clocks, then scan     |");
      $display(" ===============================================");
      for (rf_i = 0; rf_i < 4; rf_i = rf_i + 1) begin
         lead = rf_i;
         rf_park;
         @(negedge tck);
         trst_n = 1'b0;
         repeat (2) @(posedge tck);
         @(negedge tck);
         tms    = lead[0];                         // TMS for edge 1
         tdi    = 1'b0;
         #1 trst_n = 1'b1;                         // mid low phase: next rise = edge 1
         @(posedge tck);                           // edge 1
         tck_cycle(lead[1], 1'b0);                 // edge 2
         rf_scan_from_tlr(id);
         $display("INFO:  leading TMS = %b,%b", lead[0], lead[1]);
         check_eq("B_idcode", id, DUT_IDCODE);
      end

      $display(" ===============================================");
      $display("|  C: dbgresetn, documented opening, any phase  |");
      $display(" ===============================================");
      for (rf_ph = 0; rf_ph < 4; rf_ph = rf_ph + 1) begin
         rf_park;
         tms       = 1'b1;
         dbgresetn = 1'b0;
         repeat (4) @(posedge free_clk);
         @(negedge tck);
         repeat (rf_ph) @(posedge free_clk);       // walks the release across TCK
         @(posedge free_clk);
         #1 dbgresetn = 1'b1;                      // synchronous to clk
         tap_reset;
         idcode_read(id);
         check_eq("C_idcode", id, DUT_IDCODE);
      end

      $display(" ===============================================");
      $display("|  D: dbgresetn, two leading clocks, then scan  |");
      $display(" ===============================================");
      for (rf_i = 0; rf_i < 4; rf_i = rf_i + 1) begin
         lead = rf_i;
         rf_park;
         dbgresetn = 1'b0;
         repeat (4) @(posedge free_clk);
         @(negedge tck);
         tms = lead[0];                            // TMS for edge 1
         tdi = 1'b0;
         @(posedge free_clk);                      // <= 10 ns after the fall:
         #1 dbgresetn = 1'b1;                      // still inside the TCK low phase
         @(posedge tck);                           // edge 1
         tck_cycle(lead[1], 1'b0);                 // edge 2
         rf_scan_from_tlr(id);
         $display("INFO:  leading TMS = %b,%b", lead[0], lead[1]);
         check_eq("D_idcode", id, DUT_IDCODE);
      end

      // The link is usable after all of it.
      tap_reset;
      idcode_read(id);
      check_eq("idcode_after", id, DUT_IDCODE);

      repeat (8) @(posedge tck);
      stimulus_done = 1'b1;
   end
