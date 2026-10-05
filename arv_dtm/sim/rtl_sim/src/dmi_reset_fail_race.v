//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_reset_fail_race
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_reset_fail_race
// Module Description : dmireset racing a FAILING (PSLVERR) completion of the
//                      outstanding transfer: the failure is not lost.
//
//   Debug 1.0 Sec 6.1.4 dmireset: "Writing 1 to this bit clears the sticky error
//   state and resets errinfo, but does not affect outstanding DMI transactions."
//
//   A read of slave_fault_addr is held, then dtmcs is written with dmireset while
//   PREADY+PSLVERR is released k clk edges into that scan, k swept across the
//   scan's Update-DR. A monitor records the TCK edges of the failing completion
//   and of the dmireset Update-DR:
//     - completion before the reset: the reset clears the failure (op = 0);
//     - completion on the same edge or later: the failure stands (op = 2,
//       errinfo = 3).
//   Pass 2 repeats the sweep with a busy sticky set first (a dmi scan while the
//   read is in flight): the failure is held behind the busy, so whatever the
//   alignment, the scan after dmireset reports op = 2.
//----------------------------------------------------------------------------

`ifdef DTM_CJTAG
  `define RF_TAP dut.g_cjtag.u_dtm.u_tap
`else
  `define RF_TAP dut.g_jtag.u_dtm.u_tap
`endif

localparam [6:0] RF_ADDR = 7'h24;

integer rf_tck;          // enabled TCK edges since t0
integer rf_cf;           // TCK edge of the failing completion (-1 = none)
integer rf_rst;          // TCK edge of the dmireset Update-DR (-1 = none)
integer rf_clk;          // clk edges since the dtmcs write started
integer rf_rst_clk;      // clk edge of the dmireset Update-DR
integer rf_cal;
integer rf_tck0;
integer rf_cpt;          // clk edges per TCK edge during a scan
integer rf_step;
integer rf_k;
integer rf_same;
integer rf_pass;

initial begin
   rf_tck = 0; rf_cf = -1; rf_rst = -1; rf_rst_clk = -1;
end

always @(posedge `RF_TAP.tck_i) if (`RF_TAP.tck_en_i) begin
   if (`RF_TAP.complete_failed) rf_cf = rf_tck;
   if (`RF_TAP.upd_dr & `RF_TAP.ir_is_dtmcs & `RF_TAP.dr_dtmcs[16]) begin
      rf_rst     = rf_tck;
      rf_rst_clk = rf_clk;
   end
   rf_tck = rf_tck + 1;
end

task rf_launch;
   input busy;
   reg [31:0] d0;
   reg  [1:0] s0;
   begin
      slave_hold = 1'b1;
      shift_ir(IR_DMI);
      dmi_scan(RF_ADDR, 32'b0, OP_READ, d0, s0);
      idle_cycles(8);
      if (busy) begin
         dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, d0, s0);     // in flight -> busy sticky
         check_eq("busy_sticky", s0, OP_BUSY);
      end
      rf_cf = -1; rf_rst = -1; rf_rst_clk = -1;
   end
endtask

// dmireset while PREADY is released after `rel` clk edges (rel < 0: never)
task rf_reset_timed;
   input integer rel;
   begin
      fork
         dtmcs_write(32'h0001_0000);
         begin
            rf_clk = 0;
            while ((rf_rst < 0) || (rf_clk <= rel)) begin
               @(posedge free_clk);
               #1;
               rf_clk = rf_clk + 1;
               if (rf_clk == rel) slave_hold = 1'b0;
               if (rf_clk > 20000) begin
                  $display("ERROR: dmireset Update-DR never seen  %0t ns", $time);
                  error = error + 1;
                  disable rf_reset_timed;
               end
            end
         end
      join
   end
endtask

task rf_check;
   input busy;
   input integer k;
   reg [31:0] rd;
   reg  [1:0] st;
   reg [31:0] dt;
   reg  [1:0] exp_op;
   begin
      slave_hold = 1'b0;
      repeat (40) @(posedge free_clk);
      idle_cycles(16);                           // TCK edges: let the completion cross
      if (rf_cf < 0) begin
         $display("ERROR: k=%0d: no failing completion seen  %0t ns", k, $time);
         error = error + 1;
      end
      exp_op = (busy || (rf_cf >= rf_rst)) ? OP_FAILED : OP_SUCCESS;
      if (rf_cf == rf_rst) rf_same = rf_same + 1;
      shift_ir(IR_DMI);
      dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, rd, st);
      if (st !== exp_op) begin
         $display("ERROR: busy=%0d k=%0d: completion TCK %0d, dmireset TCK %0d -> op=%0d, expected %0d  %0t ns",
                  busy, k, rf_cf, rf_rst, st, exp_op, $time);
         error = error + 1;
      end
      dtmcs_read(dt);
      check_eq("errinfo", {29'd0, dt[20:18]}, (exp_op == OP_FAILED) ? 32'd3 : 32'd4);
      dtmcs_write(32'h0001_0000);                // clean up for the next pass
      shift_ir(IR_DMI);
   end
endtask

initial
   begin : test
      dtm_init;
      slave_latency    = 1;
      slave_fault_en   = 1'b1;
      slave_fault_addr = RF_ADDR;

      // Calibrate: clk edges from the start of the dtmcs write to its Update-DR
      rf_launch(1'b0);
      rf_tck0 = rf_tck;
      rf_reset_timed(-1);
      rf_cal = rf_rst_clk;
      rf_cpt = rf_cal / ((rf_rst - rf_tck0) + 1);
      if (rf_cpt < 1) rf_cpt = 1;
      rf_step = (rf_cpt > 2) ? (rf_cpt / 2) : 1;
      $display("INFO:  dmireset Update-DR %0d clk edges into the dtmcs write (%0d clk per TCK)", rf_cal, rf_cpt);
      slave_hold = 1'b0;
      repeat (40) @(posedge free_clk);
      dtmcs_write(32'h0001_0000);
      shift_ir(IR_DMI);

      for (rf_pass = 0; rf_pass < 2; rf_pass = rf_pass + 1) begin
         rf_same = 0;
         $display(" ===============================================");
         $display("|  Pass %0d: %s", rf_pass, rf_pass ? "busy sticky first" : "no sticky");
         $display(" ===============================================");
         for (rf_k = rf_cal - 8*rf_cpt; rf_k <= rf_cal + 2*rf_cpt; rf_k = rf_k + rf_step) begin
            rf_launch(rf_pass);
            rf_reset_timed(rf_k);
            rf_check(rf_pass, rf_k);
         end
         $display("INFO:  pass %0d: %0d offsets put the completion on the dmireset edge", rf_pass, rf_same);
         if (rf_same == 0) begin
            $display("ERROR: pass %0d never aligned the completion with the dmireset edge", rf_pass);
            error = error + 1;
         end
      end

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
