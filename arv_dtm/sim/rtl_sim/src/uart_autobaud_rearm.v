//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_autobaud_rearm
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_autobaud_rearm
// Module Description : A locked auto-baud link must self-heal from a WRONG lock without
//                      a chip reset -- the sync handshake's recovery leg.
//
//   The DTM locks its baud once, from the first 0x80. If the host baud later changes
//   (or the first lock was a mis-measured alias), the DTM is stuck on the wrong baud
//   and every frame it now sees is a framing error. The downstream re-arm clears the
//   lock after AB_FERR_LIM consecutive framing errors, so a resent 0x80 re-measures and
//   re-locks -- the host recovers by simply resending the sync char.
//
//   Here: lock + transact at baud A, then jump the host to a very different baud B with
//   NO resync (the DUT is now locked wrong -> B-baud traffic frames-errors). The host
//   recovery loop (uart_resync: resend 0x80 until the re-lock echo returns) drives the
//   re-arm, and a fresh transaction round-trips at baud B. The seeded DM value survives
//   (the transport re-arm does not disturb the Debug Module). Without the re-arm the
//   DUT stays locked on baud A, B-baud traffic never decodes, and the post-resync read
//   gets no response -> watchdog TIMEOUT.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      slave_latency = 0;                              // = arvern Debug Module timing

      $display(" ===================================================");
      $display("|  UART auto-baud re-arm: wrong lock self-heals      |");
      $display("|  lock@A -> host jumps to B -> resend 0x80 -> r/w@B  |");
      $display(" ===================================================");

      // --- Phase 1: lock + transact at baud A (16 clk/bit) ------------------------
      host_bit_ns = 16.0 * (FREE_HALF * 2.0);
      uart_autobaud_sync();                           // lock at baud A + validate echo
      dmi_uart(7'h14, OP_WRITE, 32'hCAFE_F00D, st, rd);
      check_eq("A_wst",  st, OP_SUCCESS);
      dmi_uart(7'h14, OP_READ,  32'h0,         st, rd);
      check_eq("A_rd",   rd, 32'hCAFE_F00D);

      // --- Phase 2: host baud jumps to B (40 clk/bit), no resync ------------------
      // The DUT is still locked on baud A, so every B-baud frame mis-samples its stop
      // bit -> framing error. AB_FERR_LIM consecutive such errors drop the lock; a
      // later 0x80 in the recovery burst then re-measures baud B and re-locks.
      host_bit_ns = 40.0 * (FREE_HALF * 2.0);
      uart_resync();                                  // resend 0x80 until re-locked

      // --- Phase 3: transact at baud B (only possible after a successful re-lock) --
      dmi_uart(7'h14, OP_READ,  32'h0,         st, rd);
      check_eq("B_persist", rd, 32'hCAFE_F00D);       // DM state intact across the re-arm
      check_eq("B_rst",     st, OP_SUCCESS);
      dmi_uart(7'h28, OP_WRITE, 32'h5A5A_A5A5, st, rd);
      dmi_uart(7'h28, OP_READ,  32'h0,         st, rd);
      check_eq("B_rd",      rd, 32'h5A5A_A5A5);

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
