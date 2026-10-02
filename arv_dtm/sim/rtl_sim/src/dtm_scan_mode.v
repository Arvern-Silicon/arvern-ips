//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dtm_scan_mode
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dtm_scan_mode
// Module Description : With scan_mode_i high, the resets the TAP synchronises
//                      are held inactive.
//
//   doc/arv_dtm.md, DFT: "A reset that is synchronised inside the IP is masked on
//   the synchroniser's output: the synchroniser flops are scan flops, so in test
//   mode their outputs are scan data" -- arv_dtm_tap masks tap_rst_n and
//   hclk_rst_n with scan_mode_i. A trst_n pulse drives the synchroniser outputs
//   low exactly as scan data would.
//
//   A) scan_mode = 1: the TAP holds IR = dmi and a sticky busy (a held read
//      collected too early). trst_n is pulsed and the synchronisers are clocked
//      back out of reset before scan_mode drops. Neither the IR nor the sticky
//      busy is lost, and the held transfer stays on the bus.
//   B) scan_mode = 0, same pulse: the TAP resets (dmistat reads 0 after it),
//      proving the pulse in A was effective.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] d0;
      reg  [1:0] s0;
      reg [31:0] rd;
      reg  [1:0] st;
      reg [31:0] dt;

      dtm_init;
      shift_ir(IR_DMI);

      $display(" ===============================================");
      $display("|  A) trst_n pulse under scan_mode              |");
      $display(" ===============================================");
      slave_hold = 1'b1;
      dmi_scan(7'h10, 32'b0, OP_READ, d0, s0);          // held on the bus
      idle_cycles(8);
      dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, rd, st);   // too early: sticky busy
      check_eq("A_busy", st, OP_BUSY);

      scan_mode = 1'b1;
      #(20);
      trst_n = 1'b0;
      #(20);
      trst_n = 1'b1;
      idle_cycles(4);                                   // TCK-side synchroniser releases
      repeat (4) @(posedge free_clk);                   // hclk-side synchroniser releases
      scan_mode = 1'b0;
      #(20);

      check_eq("A_psel_held", dmi_psel, 1'b1);          // DMI side not reset
      dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, rd, st);   // IR still dmi, sticky kept
      check_eq("A_still_busy", st, OP_BUSY);
      dtmcs_read(dt);
      check_eq("A_dmistat", {30'd0, dt[11:10]}, 32'd3);

      slave_hold = 1'b0;                                // release and recover
      idle_cycles(32);
      dtmcs_write(32'h0001_0000);
      shift_ir(IR_DMI);
      dtm_dmi_write(7'h11, 32'h5CA1_0011, s0);
      dtm_dmi_read (7'h11, rd, st);
      check_eq("A_after_op",   st, OP_SUCCESS);
      check_eq("A_after_data", rd, 32'h5CA1_0011);

      $display(" ===============================================");
      $display("|  B) the same pulse without scan_mode resets   |");
      $display(" ===============================================");
      slave_hold = 1'b1;
      dmi_scan(7'h10, 32'b0, OP_READ, d0, s0);
      idle_cycles(8);
      dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, rd, st);
      check_eq("B_busy", st, OP_BUSY);
      #(20);
      trst_n = 1'b0;
      #(20);
      trst_n = 1'b1;
      repeat (4) @(posedge free_clk);
      check_eq("B_psel_dropped", dmi_psel, 1'b0);       // transfer abandoned
      slave_hold = 1'b0;
      repeat (20) @(posedge free_clk);
      tap_reset;
      dtmcs_read(dt);
      check_eq("B_dmistat", {30'd0, dt[11:10]}, 32'd0);
      shift_ir(IR_DMI);
      dtm_dmi_read(7'h11, rd, st);
      check_eq("B_after_op",   st, OP_SUCCESS);
      check_eq("B_after_data", rd, 32'h5CA1_0011);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
