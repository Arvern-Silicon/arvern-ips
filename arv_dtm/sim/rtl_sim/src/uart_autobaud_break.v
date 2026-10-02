//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_autobaud_break
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_autobaud_break
// Module Description : A locked link must be RECONNECTABLE from any state without a
//                      chip reset -- the host-crash recovery leg the framing-error
//                      re-arm (uart_autobaud_rearm) cannot cover.
//
//   The framing-error re-arm only trips when the host baud CHANGES (every stop bit
//   then corrupts). A host that crashes and reconnects at the SAME baud produces no
//   framing error -- and it left arv_dtm_cmd stranded mid-frame (S_RX). A long low
//   (past any legal byte's low run) is the fix: it unlocks the baud AND flushes the
//   interpreter, so reconnect is uniformly break -> 0x80 -> echo from ANY state.
//
//   Two things must hold, and each has a check that FAILS without the RTL fix:
//
//   * RECOVERABILITY (the break unlock).  Phase 3 desyncs the interpreter mid-frame
//     (SYNC + 2 bytes, then "crash"), reconnects via break at the SAME baud, and
//     requires a full DMI transaction to round-trip. On the un-fixed RTL the long low
//     is just one framing error (a continuous low re-triggers no start edge), the lock
//     never drops, the resent 0x80 is swallowed by the stale S_RX, and the reconnect
//     echo never comes -> watchdog TIMEOUT.
//
//   * NO SPURIOUS WRITE (the cmd flush).  The crash is a partial WRITE aimed at a
//     canary address (SYNC + canary-addr + 0xFF). Without the flush, the stranded S_RX
//     is completed by the FIRST post-reconnect frame's bytes: its op field lands on a
//     byte whose low bits are OP_WRITE, firing a bogus write to the canary (and eating
//     the intended write). The flush parks the interpreter at SYNC so the reconnect
//     frame is clean -- the canary is untouched and the real write lands.
//
//   Phase 4 repeats the crash and reconnects at a DIFFERENT baud, confirming the break
//   hands off cleanly to a fresh measurement. The seeded DM values survive throughout
//   (the transport re-arm never disturbs the Debug Module).
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      slave_latency = 0;                              // = arvern Debug Module timing

      $display(" =====================================================");
      $display("|  UART auto-baud break: reconnect from ANY state      |");
      $display("|  lock -> crash mid-frame -> break -> 0x80 -> r/w      |");
      $display(" =====================================================");

      // --- Phase 1: lock + seed a persistent value and a canary at baud A ----------
      host_bit_ns = 16.0 * (FREE_HALF * 2.0);         // baud A = 16 clk/bit
      uart_autobaud_sync();                           // lock at baud A + validate echo
      dmi_uart(7'h14, OP_WRITE, 32'hCAFE_F00D, st, rd);
      check_eq("A_wst", st, OP_SUCCESS);
      dmi_uart(7'h30, OP_WRITE, 32'hC0DE_C0DE, st, rd);   // canary the crash frame points at
      dmi_uart(7'h14, OP_READ,  32'h0,         st, rd);
      check_eq("A_rd",  rd, 32'hCAFE_F00D);

      // --- Phase 2: a host "crash" leaves arv_dtm_cmd stranded mid-WRITE -----------
      // SYNC + addr(0x30) + one data byte(0xFF), then nothing: the interpreter is
      // parked in S_RX pointed at the canary, needing 3 more bytes. No baud change, so
      // the framing-error re-arm can NEVER fire -- only the break can rescue this.
      uart_send_byte(8'h55);                          // SYNC -> S_RX
      uart_send_byte(8'h30);                          // addr = canary
      uart_send_byte(8'hFF);                          // d31:24  (host dies here)
      #(4.0 * host_bit_ns);

      // --- Phase 3: reconnect at the SAME baud via break (the discriminating case) -
      uart_break();                                   // long low -> unlock + flush cmd
      uart_autobaud_sync();                           // 0x80 at baud A -> re-lock + echo
      // First post-reconnect frame is a WRITE. Its bytes are exactly what would finish
      // the stranded canary-write into a bogus OP_WRITE if the interpreter were NOT
      // flushed; with the flush it is a clean, independent write to 0x28.
      dmi_uart(7'h28, OP_WRITE, 32'h5A5A_A5A5, st, rd);
      dmi_uart(7'h30, OP_READ,  32'h0,         st, rd);
      check_eq("canary_safe", rd, 32'hC0DE_C0DE);     // flush prevented a spurious write
      dmi_uart(7'h28, OP_READ,  32'h0,         st, rd);
      check_eq("A_rd2",       rd, 32'h5A5A_A5A5);     // the intended write landed cleanly
      dmi_uart(7'h14, OP_READ,  32'h0,         st, rd);
      check_eq("A_persist",   rd, 32'hCAFE_F00D);     // DM state intact across the break

      // --- Phase 4: crash again, then break-reconnect at a DIFFERENT baud B --------
      // The break is a fixed-clocks watchdog (baud-independent), so it clears the A-baud
      // lock regardless; the following 0x80 at B is then measured from scratch.
      uart_send_byte(8'h55);                          // SYNC -> S_RX (crash again)
      uart_send_byte(8'h28);
      uart_send_byte(8'hBE);
      #(4.0 * host_bit_ns);

      uart_break();                                   // low at baud A -> unlock + flush cmd
      host_bit_ns = 40.0 * (FREE_HALF * 2.0);         // host now talks baud B
      uart_autobaud_sync();                           // 0x80 at B -> measure + re-lock + echo
      dmi_uart(7'h28, OP_READ,  32'h0,         st, rd);
      check_eq("B_persist", rd, 32'h5A5A_A5A5);       // DM state intact across the baud change
      check_eq("B_rst",     st, OP_SUCCESS);
      dmi_uart(7'h14, OP_WRITE, 32'h1234_5678, st, rd);
      dmi_uart(7'h14, OP_READ,  32'h0,         st, rd);
      check_eq("B_rd",      rd, 32'h1234_5678);       // full transaction round-trips at baud B

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
