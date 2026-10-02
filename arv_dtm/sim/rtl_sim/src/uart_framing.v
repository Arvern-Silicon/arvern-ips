//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_framing
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_framing
// Module Description : A UART byte with a bad stop bit must be DROPPED, not passed
//                      on as a valid byte.
//
//   Without the stop-bit check a framing error (baud mismatch or a line bit-flip
//   landing on the stop bit) is retired as a good byte -- which can slip a
//   spurious DMI write past the fixed-length interpreter. Here the SYNC (0x55)
//   that leads a WRITE-to-0x10 request is given a LOW stop bit. If the DUT honours
//   the stop bit it drops the SYNC, arv_dtm_cmd never enters S_RX, and the write
//   never happens; if it does not, the SYNC is delivered, the write executes, and
//   the seeded value is clobbered.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [1:0]  st;
      reg [31:0] rd;
      reg [7:0]  bb;
      integer    i;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      uart_autobaud_sync();                                // open the link: measure baud + eat echo

      dmi_uart(7'h10, OP_WRITE, 32'hC0DE_1234, st, rd);     // seed
      dmi_uart(7'h10, OP_READ,  32'h0,         st, rd);
      check_eq("seed_rd", rd, 32'hC0DE_1234);

      $display(" ===============================================");
      $display("|  Bad stop bit on SYNC must drop the byte      |");
      $display(" ===============================================");

      // Send a WRITE-0x10 = 0xDEADBEEF request whose SYNC has a LOW (invalid) stop
      // bit; the remaining bytes are well-formed. A DUT that validates the stop
      // bit drops the SYNC, so this whole request is inert.
      bb = 8'h55;
      uart_rx = 1'b0;  #(host_bit_ns);                      // start bit
      for (i = 0; i < 8; i = i + 1) begin
         uart_rx = bb[i]; #(host_bit_ns);                   // d0..d7 (= 0x55)
      end
      uart_rx = 1'b0;  #(host_bit_ns);                      // STOP bit LOW  <-- framing error
      uart_rx = 1'b1;  #(host_bit_ns);                      // back to idle

      uart_send_byte(8'h10);                                // addr (well-formed from here)
      uart_send_byte(8'hDE);
      uart_send_byte(8'hAD);
      uart_send_byte(8'hBE);
      uart_send_byte(8'hEF);
      uart_send_byte({6'b0, OP_WRITE});
      #(4.0 * host_bit_ns);

      // The write must NOT have taken effect: 0x10 still holds the seed.
      dmi_uart(7'h10, OP_READ, 32'h0, st, rd);
      check_eq("no_spurious_wr", rd, 32'hC0DE_1234);
      check_eq("post_st",        st, OP_SUCCESS);

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
