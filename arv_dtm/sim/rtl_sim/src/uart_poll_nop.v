//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_poll_nop
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_poll_nop
// Module Description : op = 0 (NOP) must return the LAST result without starting a
//                      new DMI transaction.
//
//   It is how a host re-reads a result it missed, or checks a status without side
//   effects. Every UART and I2C test sends read, write or hardreset; no test ever sent
//   op = 0, so the poll arm of the command decoder was never executed -- a coverage
//   hole rather than a weak check.
//
//   Two things are required, and the second is the one that makes NOP a NOP: the reply
//   repeats the previous status and data, and the DMI bus sees no new transfer. The APB
//   select is counted across the poll to prove the second.
//----------------------------------------------------------------------------

integer psel_cnt;

initial psel_cnt = 0;

always @(posedge dmi_psel) psel_cnt = psel_cnt + 1;

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;
      integer    psel_before;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      slave_latency = 2;

      uart_autobaud_sync();

      $display(" ===================================================");
      $display("|  UART: op=NOP repeats the last result, no bus op   |");
      $display(" ===================================================");

      dmi_uart(7'h30, OP_WRITE, 32'hFEED_FACE, st, rd);
      dmi_uart(7'h30, OP_READ,  32'h0,         st, rd);
      check_eq("seed_rd", rd, 32'hFEED_FACE);
      check_eq("seed_st", st, OP_SUCCESS);

      // The poll itself. Address and data are ignored for op = 0.
      psel_before = psel_cnt;
      dmi_uart(7'h00, OP_NOP, 32'h0, st, rd);
      check_eq("nop_rd", rd, 32'hFEED_FACE);
      check_eq("nop_st", st, OP_SUCCESS);
      check_eq("nop_no_bus_op", psel_cnt - psel_before, 0);

      // Repeatable, and still non-destructive.
      dmi_uart(7'h00, OP_NOP, 32'h0, st, rd);
      check_eq("nop_rd2", rd, 32'hFEED_FACE);

      // A real transaction after the poll is unaffected.
      dmi_uart(7'h31, OP_WRITE, 32'h0BAD_F00D, st, rd);
      dmi_uart(7'h31, OP_READ,  32'h0,         st, rd);
      check_eq("post_rd", rd, 32'h0BAD_F00D);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
