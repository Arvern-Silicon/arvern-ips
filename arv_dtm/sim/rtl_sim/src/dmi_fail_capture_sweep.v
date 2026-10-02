//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_fail_capture_sweep
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_fail_capture_sweep.v
// Module Description : A DMI read the subordinate fails must never be reported
//                      as a success, whichever TCK edge collects it.
//
//   Debug 1.0 Sec 6.1.5, op (read): "2: A previous operation failed. The data
//   scanned into dmi in this access will be ignored. This status is sticky".
//   A read of a PSLVERR address is launched, then collected by a nop scan after
//   n Run-Test/Idle cycles, n swept 0..12 at slave latencies 0..5, so the
//   Capture-DR of the collecting scan lands on every edge around the completion
//   -- including the one where the op retires. Each capture must read busy (3)
//   or failed (2); a success (0) hands the debugger the failed read's data.
//   Runs on JTAG and cJTAG (same TAP-level API).
//----------------------------------------------------------------------------

initial
   begin : test
      integer    lat;
      integer    n;
      reg [31:0] d0;
      reg  [1:0] s0;
      reg [31:0] cd;
      reg  [1:0] cs;

      dtm_init;
      shift_ir(IR_DMI);
      slave_fault_en   = 1'b1;
      slave_fault_addr = 7'h20;

      for (lat = 0; lat < 6; lat = lat + 1) begin
         slave_latency = lat;
         for (n = 0; n < 13; n = n + 1) begin
            dmi_scan(7'h20, 32'b0, OP_READ, d0, s0);      // launch the failing read
            idle_cycles(n);
            dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, cd, cs); // collect
            if (cs == OP_SUCCESS) begin
               $display("ERROR: latency %0d idle %0d: failed read collected as success (data 0x%0h)  %0t ns",
                        lat, n, cd, $time);
               error = error + 1;
            end
            idle_cycles(32);
            dtmcs_write(32'h0001_0000);                   // dmireset
            shift_ir(IR_DMI);
         end
      end
      check_eq("sweep_errors", error, 0);

      slave_fault_en = 1'b0;                              // the link still works
      dtm_dmi_write(7'h11, 32'h1234_5678, s0);
      dtm_dmi_read (7'h11, cd, cs);
      check_eq("after_op",   cs, OP_SUCCESS);
      check_eq("after_data", cd, 32'h1234_5678);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
