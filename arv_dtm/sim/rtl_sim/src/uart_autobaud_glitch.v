//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_autobaud_glitch
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_autobaud_glitch
// Module Description : Auto-baud MUST NOT be wedged by a spurious first low pulse.
//
//   A power-up/line glitch (or any stray low before the real 0x80) must not freeze a
//   garbage divisor: latching one on the first filtered low pulse would kill the link
//   for its lifetime, because the host's subsequent real 0x80 could never then be
//   measured.
//
//   Here the host emits a short low glitch BEFORE the real sync char, then the real
//   0x80 at 24 clk/bit. The unit rejects the glitch -- its measured bit period rounds
//   below the arithmetic floor AB_DIV_FLOOR (a sub-Nyquist run is not a legal bit
//   period) -- and stays armed, then measures the real 0x80 and round-trips ordinary
//   DMI traffic. A DUT that latched the glitch would mis-sample every following byte
//   -> no valid command -> no response -> watchdog TIMEOUT.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      // Arbitrary host baud (as in uart_autobaud): 24 clk/bit, measured by the DUT.
      host_bit_ns   = 24.0 * (FREE_HALF * 2.0);
      slave_latency = 0;                              // = arvern Debug Module timing

      $display(" ===================================================");
      $display("|  UART auto-baud: reject a pre-sync glitch, re-arm  |");
      $display("|  glitch -> idle -> real 0x80 -> DMI r/w            |");
      $display(" ===================================================");

      // --- Spurious low glitch BEFORE the sync char -------------------------------
      // ~6 free_clk cycles low: wide enough to pass the 3-tap majority filter but far
      // too short to be a legal bit period, so the RTL rejects it (measured divisor
      // rounds below AB_DIV_FLOOR) and re-arms.
      uart_rx = 1'b0;  #(60.0);
      uart_rx = 1'b1;  #(4.0 * host_bit_ns);          // return to idle; let the unit re-arm

      // --- The real one-time sync char the DUT must measure -----------------------
      uart_autobaud_sync();

      // If the glitch was rejected and THIS 0x80 measured, ordinary DMI round-trips.
      dmi_uart(7'h10, OP_WRITE, 32'hDEAD_BEEF, st, rd);
      check_eq("gl_wst@10", st, OP_SUCCESS);
      dmi_uart(7'h10, OP_READ,  32'h0,         st, rd);
      check_eq("gl_rst@10", st, OP_SUCCESS);
      check_eq("gl_rd@10",  rd, 32'hDEAD_BEEF);

      // A second address + overwrite proves it is a stable lock, not a one-shot fluke.
      dmi_uart(7'h2A, OP_WRITE, 32'h1234_5678, st, rd);
      dmi_uart(7'h2A, OP_READ,  32'h0,         st, rd);
      check_eq("gl_rd@2A",  rd, 32'h1234_5678);

      dmi_uart(7'h10, OP_WRITE, 32'hA5A5_5A5A, st, rd);
      dmi_uart(7'h10, OP_READ,  32'h0,         st, rd);
      check_eq("gl_rd@10b", rd, 32'hA5A5_5A5A);

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
