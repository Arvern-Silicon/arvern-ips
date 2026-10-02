//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_capture_addr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_capture_addr.v
// Module Description : After a successful DMI read, the dmi register's Capture-DR
//                      value holds the address that was read from.
//
//   Debug 1.0 Sec 6.1.5, op = 1 (read): "When this operation succeeds, address
//   contains the address that was read from, and data contains the value that was
//   read." Two reads from different addresses, each collected with a nop scan;
//   the captured address field must follow the read, not stay 0.
//----------------------------------------------------------------------------

task read_and_check_addr;
   input [ABITS-1:0] addr;
   input [31:0]      exp_data;
   reg   [63:0]      tdi_dr;
   reg   [63:0]      cap;
   reg   [31:0]      d0;
   reg    [1:0]      s0;
   begin
      dmi_scan(addr, 32'b0, OP_READ, d0, s0);
      idle_cycles(32);
      tdi_dr = 64'b0;                                   // nop, collects the result
      shift_dr(tdi_dr, DMI_DR_W, cap);
      check_eq("cap_op",   cap[1:0],             OP_SUCCESS);
      check_eq("cap_data", cap[33:2],            exp_data);
      check_eq("cap_addr", cap[ABITS+33:34],     addr);
   end
endtask

initial
   begin : test
      reg [31:0] rd;
      reg  [1:0] st;
      dtm_init;
      dtm_dmi_write(7'h11, 32'h1111_0011, st);
      dtm_dmi_write(7'h2A, 32'h2A2A_002A, st);
      read_and_check_addr(7'h11, 32'h1111_0011);
      read_and_check_addr(7'h2A, 32'h2A2A_002A);
      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
