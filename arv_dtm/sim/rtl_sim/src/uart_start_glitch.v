//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_start_glitch
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_start_glitch
// Module Description : A low pulse on an idle, locked RX line that is wider than
//                      the majority filter but shorter than half a bit is not a
//                      start bit: no byte is received.
//
//   The receiver re-checks the line at the middle of the start bit; a line that
//   is high again there was a glitch, and the receiver returns to idle. Without
//   that check the pulse is taken as a start bit and the stop-bit-high line
//   reads as 0xFF -- in the op slot of a request, op 3, dmihardreset.
//
//   Widths from 3 clk (just past the 3-tap filter) up to 40 % of a bit; a pulse
//   still low at the middle of the start bit is indistinguishable from a real
//   start bit. After the glitches a DMI write / read must round-trip.
//----------------------------------------------------------------------------
reg [7:0] rx_count;
initial rx_count = 8'h00;
always @(posedge free_clk)
   if (dut.g_uart.u_dtm.rx_valid) rx_count <= rx_count + 8'd1;

integer w;

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;
      reg [7:0]  rx_before;
      dtm_init;
      dtm_dmi_write(7'h21, 32'h0BAD_F00D, st);
      $display(" ===============================================");
      $display("|  Short low pulses on an idle RX line          |");
      $display(" ===============================================");
      rx_before = rx_count;
      for (w = 3; (FREE_HALF * 2.0 * w) < (host_bit_ns * 0.4); w = w + 1) begin
         uart_rx = 1'b0;  #(FREE_HALF * 2.0 * w);
         uart_rx = 1'b1;  #(host_bit_ns * 12);
      end
      check_eq("no_byte_from_glitch", rx_count - rx_before, 0);
      dtm_dmi_write(7'h22, 32'h600D_CAFE, st);
      dtm_dmi_read (7'h22, rd, st);
      check_eq("rd_after_glitch", rd, 32'h600D_CAFE);
      dtm_dmi_read (7'h21, rd, st);
      check_eq("rd_untouched",    rd, 32'h0BAD_F00D);
      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
