//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_fail_behind_busy
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_fail_behind_busy.v
// Module Description : A read that fails after the debugger has already seen
//                      busy is still reported as failed once busy is cleared.
//
//   Debug 1.0 B.2.1: "The busy condition must be cleared by writing dmireset in
//   dtmcs, and then the second scan must be performed again. This process must
//   be repeated until op returns 0." Sec 6.1.5 op = 2: "A previous operation
//   failed ... This status is sticky". Sec 6.1.4 errinfo: "updated whenever op
//   is updated by the hardware".
//
//   The subordinate holds a PSLVERR read; the collecting nop scan captures busy;
//   the read then completes failed. The debugger follows B.2.1 (dmireset, repeat
//   the nop): that scan must report failed (2) with errinfo = 3, not success with
//   the failed read's data. A second dmireset then returns the link to success.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] d0;
      reg  [1:0] s0;
      reg [31:0] cd;
      reg  [1:0] cs;
      reg [31:0] dt;

      dtm_init;
      shift_ir(IR_DMI);
      slave_fault_en   = 1'b1;
      slave_fault_addr = 7'h20;
      slave_hold       = 1'b1;

      dmi_scan(7'h20, 32'b0, OP_READ, d0, s0);          // launch, held by the slave
      idle_cycles(8);
      dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, cd, cs);   // too early
      check_eq("early_busy", cs, OP_BUSY);

      slave_hold = 1'b0;                                // completes with PSLVERR
      idle_cycles(32);

      dtmcs_write(32'h0001_0000);                       // B.2.1: dmireset ...
      shift_ir(IR_DMI);
      dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, cd, cs);   // ... and repeat the scan
      check_eq("retry_failed", cs, OP_FAILED);
      dtmcs_read(dt);
      check_eq("errinfo_device", {29'd0, dt[20:18]}, 32'd3);
      check_eq("dmistat_failed", {30'd0, dt[11:10]}, 32'd2);

      dtmcs_write(32'h0001_0000);                       // clear the failure
      dtmcs_read(dt);
      check_eq("dmistat_clear", {30'd0, dt[11:10]}, 32'd0);
      check_eq("errinfo_clear", {29'd0, dt[20:18]}, 32'd4);

      slave_fault_en = 1'b0;                            // the link still works
      shift_ir(IR_DMI);
      dtm_dmi_write(7'h11, 32'hCAFE_0011, s0);
      dtm_dmi_read (7'h11, cd, cs);
      check_eq("after_op",   cs, OP_SUCCESS);
      check_eq("after_data", cd, 32'hCAFE_0011);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
