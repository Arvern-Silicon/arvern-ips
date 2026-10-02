//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_drop_misframe
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_drop_misframe
// Module Description : A framing error inside a request's payload discards that
//                      request; it is never completed with the next bytes.
//
//   The UART frame is fixed-length and a byte with a low stop bit is dropped. If
//   the interpreter just waited for the missing byte, the next request's SYNC
//   would fill the op slot (0x55 -> op = 1, a READ nobody sent) and its response
//   would be paired with the broken request -- a write acknowledged as a success
//   although it never happened.
//
//   A) Streaming: W(0x10) with a framing error on its d23:16 byte, immediately
//      followed by R(0x12). Exactly one response must come back, and it must be
//      R(0x12)'s; 0x10 must keep its seed.
//   B) Last frame of a burst: W(0x10) with a framing error and nothing behind it.
//      The next request (a DTMSTS read) must be answered as itself.
//----------------------------------------------------------------------------

task uart_send_byte_ferr;                               // low stop bit
   input [7:0] b;
   integer i;
   begin
      uart_rx = 1'b0;  #(host_bit_ns);
      for (i = 0; i < 8; i = i + 1) begin
         uart_rx = b[i]; #(host_bit_ns);
      end
      uart_rx = 1'b0;  #(host_bit_ns);                  // framing error
      uart_rx = 1'b1;  #(host_bit_ns);
   end
endtask

task send_write_ferr;                                   // W(0x10, 0xDEADBEEF), d23:16 broken
   begin
      uart_send_byte(8'h55);
      uart_send_byte(8'h10);
      uart_send_byte(8'hDE);
      uart_send_byte_ferr(8'hAD);
      uart_send_byte(8'hBE);
      uart_send_byte(8'hEF);
      uart_send_byte({6'b0, OP_WRITE});
   end
endtask

initial
   begin : test
      reg [1:0]  st;
      reg [31:0] rd;
      reg [7:0]  s, b3, b2, b1, b0;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      uart_autobaud_sync();

      dmi_uart(7'h10, OP_WRITE, 32'h5EED_0010, st, rd);
      dmi_uart(7'h12, OP_WRITE, 32'h5EED_0012, st, rd);

      $display(" ===============================================");
      $display("|  A) broken write streamed ahead of a read     |");
      $display(" ===============================================");
      send_write_ferr;
      uart_send_byte(8'h55);                            // R(0x12)
      uart_send_byte(8'h12);
      uart_send_byte(8'h00);  uart_send_byte(8'h00);
      uart_send_byte(8'h00);  uart_send_byte(8'h00);
      uart_send_byte({6'b0, OP_READ});
      #(80.0 * host_bit_ns);
      check_eq("A_resp_bytes", (rx_wr - rx_rd) & 255, 5);
      fifo_pop(s); fifo_pop(b3); fifo_pop(b2); fifo_pop(b1); fifo_pop(b0);
      check_eq("A_status", s[1:0], OP_SUCCESS);
      check_eq("A_rdata",  {b3, b2, b1, b0}, 32'h5EED_0012);   // R(0x12)'s, not a READ of 0x10
      while (rx_wr !== rx_rd) rx_rd = (rx_rd + 1) & 255;
      dmi_uart(7'h10, OP_READ, 32'h0, st, rd);
      check_eq("A_no_write", rd, 32'h5EED_0010);

      $display(" ===============================================");
      $display("|  B) broken write as the last frame            |");
      $display(" ===============================================");
      send_write_ferr;
      #(40.0 * host_bit_ns);
      check_eq("B_no_resp", (rx_wr - rx_rd) & 255, 0);
      dmi_uart(7'h7F, OP_READ, 32'h0, st, rd);          // DTMSTS
      check_eq("B_dtmsts_st",    st,       OP_SUCCESS);
      check_eq("B_dtmsts_depth", rd[15:8], `UART_FIFO_DEPTH);
      check_eq("B_dtmsts_zero",  rd & 32'hFFFF_00FE, 32'h0);
      dmi_uart(7'h10, OP_READ, 32'h0, st, rd);
      check_eq("B_no_write", rd, 32'h5EED_0010);

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
