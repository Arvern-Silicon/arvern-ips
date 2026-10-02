//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_overrun
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_overrun
// Module Description : RX-FIFO overrun detection + write-1-to-clear.
//
//   If the host streams MORE bytes ahead than the FIFO can hold while the DTM is
//   stalled (not draining), the excess is dropped and rx_overrun latches (sticky),
//   readable via DTMSTS (0x7F) bit[0].
//
//   Method: stall the DTM by holding the DMI response (slave_hold) for an in-flight
//   READ -- the interpreter is blocked waiting for the response and cannot drain the
//   RX FIFO. Then flood 48 bytes (> the built depth of 32) so the FIFO overflows. The
//   flood is 0x00 (NOT the 0x55 SYNC), so once drained the interpreter stays in its
//   SYNC-hunt idle -- no spurious frame, no bus access, and later requests parse clean.
//   Release the stall (letting the in-flight op complete first), then read DTMSTS:
//   rx_overrun must be 1. Finally W1C-clear it and confirm it reads back 0.
//----------------------------------------------------------------------------

//=============================================================================
// Send a request frame WITHOUT popping its response (dmi_uart's request half).
//=============================================================================
task uart_send_req;
    input [ABITS-1:0] addr;
    input [1:0]       op;
    input [31:0]      data;
    begin
        uart_send_byte(8'h55);                          // SYNC
        uart_send_byte({{(8-ABITS){1'b0}}, addr});
        uart_send_byte(data[31:24]);
        uart_send_byte(data[23:16]);
        uart_send_byte(data[15:8]);
        uart_send_byte(data[7:0]);
        uart_send_byte({6'b0, op});
    end
endtask

task uart_pop_resp;
    output [1:0]  status;
    output [31:0] rdata;
    reg [7:0] s, b3, b2, b1, b0;
    begin
        fifo_pop(s);
        fifo_pop(b3);
        fifo_pop(b2);
        fifo_pop(b1);
        fifo_pop(b0);
        status = s[1:0];
        rdata  = {b3, b2, b1, b0};
    end
endtask

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;
      integer    k;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      uart_autobaud_sync();                             // open the link: measure baud + eat echo

      slave_latency = 0;                                // = arvern Debug Module timing

      // Seed the address the stalled READ will target, so we can check its returned
      // data once the stall is released.
      dmi_uart(7'h10, OP_WRITE, 32'hC0DE_1234, st, rd);

      $display(" ===============================================");
      $display("|  Flood > FIFO depth while stalled -> overrun  |");
      $display(" ===============================================");

      // --- Stall the DTM: hold the response for an in-flight READ ------------------
      slave_hold = 1'b1;
      uart_send_req(7'h10, OP_READ, 32'h0);             // launches the DMI read, then stalls
      #(3.0 * host_bit_ns);                             // let the op reach the held ACCESS phase

      // --- Flood 48 bytes (> depth 32) of 0x00 while the FIFO cannot drain ---------
      // 0x00 is not SYNC, so after drain the interpreter stays cleanly in SYNC-hunt.
      for (k = 0; k < 48; k = k + 1)
         uart_send_byte(8'h00);

      // --- Release the stall; the in-flight READ completes and responds -----------
      slave_hold = 1'b0;
      uart_pop_resp(st, rd);                            // exactly the stalled READ's 5-byte reply
      check_eq("stalled_st", st, OP_SUCCESS);
      check_eq("stalled_rd", rd, 32'hC0DE_1234);

      repeat (200) @(posedge free_clk);                 // let the FIFO fully drain the 0x00 flood

      $display(" ===============================================");
      $display("|  DTMSTS: rx_overrun latched, then W1C-clear   |");
      $display(" ===============================================");

      // Overrun must be set now.
      dmi_uart(7'h7F, OP_READ, 32'h0, st, rd);
      check_eq("ovr_rd_st", st,    OP_SUCCESS);
      check_eq("overrun",   rd[0], 1'b1);               // sticky overrun latched
      check_eq("depth_ok",  rd[15:8], 8'd32);

      // Write-1-to-clear, then confirm it reads back 0.
      dmi_uart(7'h7F, OP_WRITE, 32'h0000_0001, st, rd);
      check_eq("w1c_st", st, OP_SUCCESS);
      dmi_uart(7'h7F, OP_READ, 32'h0, st, rd);
      check_eq("cleared_st", st,    OP_SUCCESS);
      check_eq("cleared",    rd[0], 1'b0);              // overrun cleared

      // Link still healthy: a normal transaction round-trips.
      dmi_uart(7'h10, OP_READ, 32'h0, st, rd);
      check_eq("after_rd", rd, 32'hC0DE_1234);

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
