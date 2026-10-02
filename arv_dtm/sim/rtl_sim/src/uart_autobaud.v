//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_autobaud
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_autobaud
// Module Description : Auto-baud proof. The DTM is self-calibrating, so the host is
//                      free to pick any baud; here it drives 24 clk/bit. It
//                      sends the single 0x80 sync char, validates the 0x80 the DUT
//                      echoes back at the measured baud (the sync handshake), and runs
//                      DMI write/read transactions. They can only succeed if the DUT
//                      measured the host bit period from the 0x80 and retuned both its
//                      RX sampling and its TX baud -- i.e. the ported openMSP430
//                      auto-sync works.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      // Drive an arbitrary host baud (24 clk/bit); the DUT has no configured baud, so
      // it must measure this from the 0x80 to decode anything at all.
      host_bit_ns   = 24.0 * (FREE_HALF * 2.0);
      slave_latency = 0;                              // = arvern Debug Module timing

      $display(" ===============================================");
      $display("|   UART auto-baud: measure 0x80, then DMI r/w  |");
      $display("|   host = 24 clk/bit (DUT measures it)         |");
      $display(" ===============================================");

      // One-time sync char the DUT measures to learn the host baud.
      uart_autobaud_sync();

      // If measurement worked, ordinary DMI transactions now round-trip.
      dmi_uart(7'h10, OP_WRITE, 32'hDEAD_BEEF, st, rd);
      check_eq("ab_wst@10", st, OP_SUCCESS);
      dmi_uart(7'h10, OP_READ,  32'h0,         st, rd);
      check_eq("ab_rst@10", st, OP_SUCCESS);
      check_eq("ab_rd@10",  rd, 32'hDEAD_BEEF);

      // A second address + overwrite proves it is not a one-shot fluke.
      dmi_uart(7'h2A, OP_WRITE, 32'h1234_5678, st, rd);
      dmi_uart(7'h2A, OP_READ,  32'h0,         st, rd);
      check_eq("ab_rd@2A",  rd, 32'h1234_5678);

      dmi_uart(7'h10, OP_WRITE, 32'hA5A5_5A5A, st, rd);
      dmi_uart(7'h10, OP_READ,  32'h0,         st, rd);
      check_eq("ab_rd@10b", rd, 32'hA5A5_5A5A);

      // Failed status still carried back verbatim at the measured baud.
      slave_fault_en   = 1'b1;
      slave_fault_addr = 7'h30;
      dmi_uart(7'h30, OP_READ, 32'h0, st, rd);
      check_eq("ab_failed", st, OP_FAILED);
      slave_fault_en   = 1'b0;

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
