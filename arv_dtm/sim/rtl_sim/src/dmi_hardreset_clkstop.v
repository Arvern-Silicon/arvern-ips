//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_hardreset_clkstop
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_hardreset_clkstop
// Module Description : dmihardreset and a relaunch while the DMI clock is stopped:
//                      the documented behaviour and its recovery.
//
//   A read is launched with the oscillator stopped, the debugger sees busy,
//   issues dmireset (still busy: the op is outstanding), then dmihardreset and
//   relaunches the read -- all before the oscillator runs again. The hardreset
//   is seen once the clock resumes, but the relaunch is lost (the request toggle
//   returned to its old level while the DMI side could not sample it), so the
//   link stays busy. A second dmihardreset recovers it and the next read
//   returns its data (doc/arv_dtm.md, DMI clock requirements).
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] d0;
      reg  [1:0] s0;
      reg [31:0] rd;
      reg  [1:0] st;

      dtm_init;
      shift_ir(IR_DMI);
      slave_mem[7'h21] = 32'h2121_0021;
      repeat (4) @(posedge free_clk);

      clk_gate = 1'b0;                                  // oscillator stopped
      dmi_scan(7'h21, 32'b0, OP_READ, d0, s0);          // launch #1: unseen
      idle_cycles(16);
      dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, rd, st);
      check_eq("stopped_busy", st, OP_BUSY);
      dtmcs_write(32'h0001_0000);                       // dmireset
      shift_ir(IR_DMI);
      dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, rd, st);
      check_eq("still_busy", st, OP_BUSY);
      dtmcs_write(32'h0002_0000);                       // dmihardreset
      shift_ir(IR_DMI);
      dmi_scan(7'h21, 32'b0, OP_READ, d0, s0);          // relaunch: lost
      idle_cycles(4);
      clk_gate = 1'b1;                                  // oscillator resumes
      repeat (100) @(posedge free_clk);

      dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, rd, st);
      check_eq("relaunch_lost", st, OP_BUSY);

      dtmcs_write(32'h0002_0000);                       // recovery: second dmihardreset
      shift_ir(IR_DMI);
      dmi_read(7'h21, DTM_IDLE_N, rd, st);
      check_eq("recovered_op",   st, OP_SUCCESS);
      check_eq("recovered_data", rd, 32'h2121_0021);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
