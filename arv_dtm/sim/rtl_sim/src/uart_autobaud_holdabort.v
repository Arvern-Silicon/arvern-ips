//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_autobaud_holdabort
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_autobaud_holdabort
// Module Description : A line that goes low again during trailing-high validation must
//                      abandon the measurement, not lock on it.
//
//   Auto-baud runs in three phases: arm, time the low run, then hold -- the line must
//   stay high for ~1.5 measured bit periods before the divisor is committed. That last
//   phase is what separates a real 0x80 from any other low run of similar length, and
//   its reject arm (`rxd_fe` during hold) had never been executed. `uart_autobaud_glitch`
//   disturbs the ARM phase, `uart_autobaud_rearm` recovers from an already-wrong lock;
//   neither aborts a measurement mid-hold.
//
//   Stimulus: a well-formed low run, released high for only a fraction of the hold
//   window, then pulled low again. A DTM that locked anyway would be locked on a
//   fabricated divisor, and the genuine 0x80 that follows would frame-error instead of
//   completing the handshake.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      host_bit_ns   = 20.0 * (FREE_HALF * 2.0);
      slave_latency = 0;

      $display(" ===================================================");
      $display("|  UART: low during hold aborts the measurement     |");
      $display(" ===================================================");

      // 0x80's low run is start + d0..d6 = 8 bit-times, which is what phase 2 times.
      uart_rx = 1'b0;  #(8.0 * host_bit_ns);

      // Release high for well under the ~1.5-bit hold target, then pull low again:
      // the falling edge lands inside the hold window and must reject the measurement.
      uart_rx = 1'b1;  #(0.5 * host_bit_ns);
      uart_rx = 1'b0;  #(2.0 * host_bit_ns);
      uart_rx = 1'b1;  #(8.0 * host_bit_ns);         // back to idle, nothing locked

      // Nothing may have been echoed: an echo would mean a byte was framed against a
      // divisor that should never have been committed.
      check_eq("no_echo_abort", (rx_wr !== rx_rd), 1'b0);

      // The genuine sync char now measures and locks cleanly.
      uart_autobaud_sync();

      dmi_uart(7'h40, OP_WRITE, 32'h5EED_1234, st, rd);
      check_eq("post_wst", st, OP_SUCCESS);
      dmi_uart(7'h40, OP_READ,  32'h0,         st, rd);
      check_eq("post_rd",  rd, 32'h5EED_1234);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
