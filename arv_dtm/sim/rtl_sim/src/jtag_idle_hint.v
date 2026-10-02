//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    jtag_idle_hint
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : jtag_idle_hint.v
// Module Description : A debugger that waits exactly the dtmcs.idle hint in
//                      Run-Test/Idle between a DMI scan and the next one never
//                      sees BUSY.
//
//   Debug 1.0 Sec 6.1.4 (dtmcs.idle): the number of cycles a debugger should
//   spend in Run-Test/Idle after every DMI scan to avoid a busy return code.
//   The hint is read from dtmcs and used as the settle count for a series of
//   writes and read-backs, with the DMI slave at one wait state (the aRVern DM).
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] dtmcs;
      reg [31:0] rd;
      reg  [1:0] st;
      integer    idle, k;
      dtm_init;
      slave_latency = 1;
      dtmcs_read(dtmcs);
      idle = dtmcs[14:12];
      $display("dtmcs.idle = %0d", idle);
      shift_ir(IR_DMI);
      for (k = 0; k < 8; k = k + 1) begin
         dmi_write(7'h10 + k, 32'hA000_0000 + k, idle);
         dmi_read (7'h10 + k, idle, rd, st);
         check_eq("idle_hint_status", st, OP_SUCCESS);
         check_eq("idle_hint_rdata",  rd, 32'hA000_0000 + k);
      end
      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
