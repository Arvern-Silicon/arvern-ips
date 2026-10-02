//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_pipeline
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_pipeline
// Module Description : Request pipelining -- the RX byte-FIFO must let the host
//                      STREAM several DMI request frames back-to-back (no gap for
//                      responses) and still get ALL responses, correct and in order.
//
//   DISCRIMINATION (why this fails without the FIFO):
//   A request frame is 7 bytes = 70 bit-times; a response is 5 bytes = 50 bit-times.
//   The host streams K frames continuously with NO pops in between, so request k+1's
//   bytes are on the wire while the DTM is still transmitting request k's response
//   (full-duplex: 50-bit-time response TX fully overlaps the 70-bit-time next-request
//   RX). On RTL WITHOUT the RX FIFO, every request byte that lands while the DTM is
//   mid-response (or mid-DMI-op) is DROPPED, so requests 2..K are never assembled and
//   their responses never come -- the (2nd) uart_pop_resp blocks forever -> watchdog
//   TIMEOUT -> FAIL. With the FIFO those bytes are buffered and drained as the DTM
//   frees up, so all K responses arrive. The existing tests never catch this because
//   dmi_uart() pops each response before sending the next request (strictly serial,
//   with gaps) -- this test is the first to overlap RX with response TX.
//----------------------------------------------------------------------------

//=============================================================================
// Split-half helpers: send a request frame WITHOUT popping its response (so the
// host can stream many ahead), and pop one 5-byte response later. Together these
// are exactly dmi_uart() cut in two.
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
      integer    NREQ;

      NREQ = 6;                                         // K >= 4; 6 distinct addr/data

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      uart_autobaud_sync();                             // open the link: measure baud + eat echo

      slave_latency = 0;                                // = arvern Debug Module timing (fast drain)

      $display(" ======================================================");
      $display("|  UART request pipelining: K frames streamed ahead     |");
      $display("|  all responses must come back, correct and in order   |");
      $display(" ======================================================");

      // --- Phase 1: stream K WRITE requests back-to-back (NO response pops) --------
      // addr[k] = 0x10+k, data[k] = 0xDEAD_BE00 | k -- all distinct.
      for (k = 0; k < NREQ; k = k + 1)
         uart_send_req(7'h10 + k, OP_WRITE, 32'hDEAD_BE00 + k);

      // Now drain all K write responses; every one must report success.
      for (k = 0; k < NREQ; k = k + 1) begin
         uart_pop_resp(st, rd);
         check_eq("wr_st", st, OP_SUCCESS);
      end

      // --- Phase 2: stream K READ requests back-to-back, then pop all K responses --
      // Each must return the value written to its address, in issue order.
      for (k = 0; k < NREQ; k = k + 1)
         uart_send_req(7'h10 + k, OP_READ, 32'h0);

      for (k = 0; k < NREQ; k = k + 1) begin
         uart_pop_resp(st, rd);
         check_eq("rd_st",   st, OP_SUCCESS);
         check_eq("rd_data", rd, 32'hDEAD_BE00 + k);
      end

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
