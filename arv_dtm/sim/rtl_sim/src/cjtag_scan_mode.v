//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    cjtag_scan_mode
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : cjtag_scan_mode
// Module Description : With scan_mode_i high the cJTAG target never drives TMSC and
//                      does not decode escapes; once scan_mode_i drops, an escape
//                      and an activation bring the link back.
//
//   doc/arv_dtm_cjtag.md, Pins: "scan_mode_i ... 1 = test mode (shift and capture):
//   hold internally generated resets inactive, release TMSC".
//   doc/arv_dtm_cjtag.md, DFT / scan: "scan_mode_i also forces tmsc_oe_o low, so the
//   target never drives the shared bidirectional pad while the tester owns it."
//   Same table: "TCKC sampled as data by the escape detector | TCKC ANDed with
//   ~scan_mode_i before its synchroniser" -- the detector counts TMSC changes "while
//   TCKC is high" (Escapes), so with scan_mode_i high it sees TCKC low and no escape
//   is classified: the link stays online.
//   doc/arv_dtm_cjtag.md, Escapes: 8 or more changes = "reset | node goes Offline";
//   "Any escape other than a custom one clears online".
//
//   A) Link up (activation, IR = DMI), a write + read round trip; the DUT is seen
//      driving TMSC in the TDO phase of an ordinary scan (so the check in B is
//      discriminating).
//   B) scan_mode = 1 (raised with TCKC low). The host sends OScan1 packets and KEEPS
//      DRIVING TMSC through every TDO phase (TLR, RTI, a 32-bit DR scan); tmsc_oe
//      must stay 0 on every clk_i cycle (explicit monitor, plus the bench contention
//      monitor). A 10-change reset escape is then issued: masked, online stays 1.
//   C) scan_mode = 0 (TCKC low). A reset escape takes the node Offline, a
//      selection escape + activation brings it back: IDCODE, dtmcs.dmistat = 0 and
//      a DMI write + read round trip.
//
//   Not covered: the masks on the internally generated resets (clk_rst_n,
//   tap_rst_n). The doc makes dbgresetn_i the integrator's to hold inactive in test
//   mode and an escape (the only way to drop `online`) is masked in scan mode, so no
//   in-contract stimulus makes those masks observable.
//----------------------------------------------------------------------------

reg     csm_cnt_en;
integer csm_drv;

initial begin
   csm_cnt_en = 1'b0;
   csm_drv    = 0;
end

// scan_mode high: the target must never enable its TMSC driver.
always @(negedge free_clk)
   if ((scan_mode === 1'b1) && (tmsc_dut_oe !== 1'b0)) begin
      $display("ERROR: tmsc_oe_o=%b while scan_mode_i=1  %0t ns", tmsc_dut_oe, $time);
      error = error + 1;
   end

always @(negedge free_clk)
   if (csm_cnt_en && (tmsc_dut_oe === 1'b1)) csm_drv = csm_drv + 1;

// One OScan1 packet with the HOST driving TMSC in all three phases (the tester owns
// the pad). Same TCKC timing as cjtag_bit.
task csm_bit_hold;
   input tms_val;
   input tdi_val;
   begin
      host_tmsc_oe = 1'b1;  host_tmsc = ~tdi_val;
      repeat (CJHALF) @(posedge free_clk);
      tckc = 1'b1;  repeat (CJHALF) @(posedge free_clk);
      tckc = 1'b0;  repeat (CJHALF) @(posedge free_clk);
      host_tmsc = tms_val;
      repeat (CJHALF) @(posedge free_clk);
      tckc = 1'b1;  repeat (CJHALF) @(posedge free_clk);
      tckc = 1'b0;  repeat (CJHALF) @(posedge free_clk);
      host_tmsc = ~tms_val;                               // host keeps driving the TDO phase
      repeat (CJHALF) @(posedge free_clk);
      tckc = 1'b1;  repeat (CJHALF) @(posedge free_clk);
      tckc = 1'b0;  repeat (CJHALF) @(posedge free_clk);
      host_tmsc = 1'b1;
   end
endtask

initial
   begin : test
      reg [31:0] id;
      reg [31:0] dt;
      reg [31:0] rd;
      reg  [1:0] st;
      integer    k;

      dtm_init;                                           // activate, TLR -> RTI, IR = DMI
      slave_latency = 1;

      $display(" ===============================================");
      $display("|  A) link up, DUT drives the TDO phase         |");
      $display(" ===============================================");
      check_eq("A_online", dut.g_cjtag.u_dtm.online, 1'b1);
      csm_cnt_en = 1'b1;
      dtm_dmi_write(7'h15, 32'h5CA0_0015, st);
      dtm_dmi_read (7'h15, rd, st);
      csm_cnt_en = 1'b0;
      check_eq("A_op",   st, OP_SUCCESS);
      check_eq("A_data", rd, 32'h5CA0_0015);
      check_eq("A_dut_drove", (csm_drv > 0), 1'b1);

      $display(" ===============================================");
      $display("|  B) scan_mode = 1: host drives every phase    |");
      $display(" ===============================================");
      repeat (4) @(posedge free_clk);                     // TCKC is low here
      scan_mode = 1'b1;
      repeat (4) @(posedge free_clk);
      check_eq("B_oe_low", tmsc_dut_oe, 1'b0);
      for (k = 0; k < 5; k = k + 1) csm_bit_hold(1'b1, 1'b0);   // -> TLR (IR = IDCODE)
      csm_bit_hold(1'b0, 1'b0);                           // -> RTI
      csm_bit_hold(1'b1, 1'b0);                           // -> Select-DR
      csm_bit_hold(1'b0, 1'b0);                           // -> Capture-DR
      csm_bit_hold(1'b0, 1'b0);                           // -> Shift-DR
      for (k = 0; k < 32; k = k + 1)
         csm_bit_hold((k == 31) ? 1'b1 : 1'b0, k[0]);     // 32 bits, last -> Exit1-DR
      csm_bit_hold(1'b1, 1'b0);                           // -> Update-DR
      csm_bit_hold(1'b0, 1'b0);                           // -> RTI
      check_eq("B_online_pkts", dut.g_cjtag.u_dtm.online, 1'b1);

      cjtag_escape;                                       // 10 changes: a reset escape
      repeat (40) @(posedge free_clk);
      check_eq("B_esc_masked", dut.g_cjtag.u_dtm.online, 1'b1);

      $display(" ===============================================");
      $display("|  C) scan_mode = 0: escape + activation        |");
      $display(" ===============================================");
      host_tmsc_oe = 1'b0;                                // tester hands the pad back
      repeat (4) @(posedge free_clk);                     // TCKC is low here
      scan_mode = 1'b0;
      repeat (8) @(posedge free_clk);
      cjtag_escape_n(10);                                 // reset escape -> Offline
      repeat (20) @(posedge free_clk);
      check_eq("C_offline", dut.g_cjtag.u_dtm.online, 1'b0);
      cjtag_active_done = 1'b0;
      tap_reset;                                          // selection escape + code, TLR -> RTI
      check_eq("C_online", dut.g_cjtag.u_dtm.online, 1'b1);
      idcode_read(id);
      check_eq("C_idcode", id, DUT_IDCODE);
      dtmcs_read(dt);
      check_eq("C_dmistat", {30'd0, dt[11:10]}, 32'd0);
      shift_ir(IR_DMI);
      dtm_dmi_write(7'h16, 32'hA11C_E016, st);
      dtm_dmi_read (7'h16, rd, st);
      check_eq("C_op",   st, OP_SUCCESS);
      check_eq("C_data", rd, 32'hA11C_E016);
      dtm_dmi_read (7'h15, rd, st);
      check_eq("C_old_data", rd, 32'h5CA0_0015);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
