//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_slow_baud
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_slow_baud
// Module Description : Auto-baud at the SLOW end of the legal range.
//
//   Every other UART test drives ~16-24 clk/bit, so the measured divisor is a
//   small number and the baud counters only ever use their bottom ~5 bits. A
//   stuck bit anywhere above that would be invisible: the divisor, the half-bit
//   centring, and both RX/TX bit counters would all still behave.
//
//   The bench normally elaborates AB_BREAK_CLKS=700 to keep break tests short, and
//   AB_DIV_CEIL = AB_BREAK_CLKS>>4 then caps the measurable bit period at 43 clocks:
//   anything slower is rejected by ab_div_ok, and the divisor chain uses at most
//   6 bits.
//
//   +define+SLOW_BAUD therefore raises AB_BREAK_CLKS to 65536 (ceiling 4096) AND
//   stretches the watchdog, since one byte now costs 10 x 4096 clocks.
//
//   Bits above 12 stay untested: lifting the ceiling to the shipping default
//   (65536 clk/bit) would cost 6.5 ms of simulated time PER BYTE. A deliberate
//   limit, not a waiver -- those bits are reachable on real hardware.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      // Slow but legal: 4096 clk/bit, well under AB_DIV_CEIL (65536).
      host_bit_ns   = 4096.0 * (FREE_HALF * 2.0);
      slave_latency = 0;

      $display(" ===============================================");
      $display("|   UART auto-baud at 4096 clk/bit (slow end)   |");
      $display(" ===============================================");

      // The DUT has no configured baud: it must measure this long bit period.
      uart_autobaud_sync();

      // If the measurement is right, ordinary traffic round-trips at this baud.
      dmi_uart(7'h10, OP_WRITE, 32'hDEAD_BEEF, st, rd);
      check_eq("slow_wst", st, OP_SUCCESS);
      dmi_uart(7'h10, OP_READ,  32'h0,         st, rd);
      check_eq("slow_rst", st, OP_SUCCESS);
      check_eq("slow_rd",  rd, 32'hDEAD_BEEF);

      // A second transfer at a different address: proves the divisor persists
      // rather than being re-measured (or drifting) per byte.
      dmi_uart(7'h2A, OP_WRITE, 32'h5A5A_A5A5, st, rd);
      dmi_uart(7'h2A, OP_READ,  32'h0,         st, rd);
      check_eq("slow_rd2", rd, 32'h5A5A_A5A5);

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
