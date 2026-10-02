//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_ferr_ahead_queued
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_ferr_ahead_queued
// Module Description : A framing error discards a request queued AHEAD of the
//                      broken one; the executing request is still answered, and the
//                      documented recovery performs the lost write exactly once.
//
//   doc/arv_dtm_uart.md, Behaviour at a glance: "Byte with a low stop bit (framing
//   error) | Dropped, and the request it belongs to is discarded: the RX FIFO is
//   flushed and the interpreter resynchronises to the next 0x55, so that request
//   and every request still queued in the RX FIFO, before or behind it, get no
//   response." "Bytes arriving while a request is executing or a response is being
//   sent | Queued in the RX FIFO".
//   Request pipelining: "An op already in execution completes normally." ... "a host
//   that misses an expected response ... reconnects with a break, reads DTMSTS,
//   clears the flag if it is set, and resends from the first request that got no
//   reply. A framing error (below) loses requests the same way."
//   Host protocol contract: "after a missing response: break, 0x80, echo, read
//   DTMSTS (clear rx_overrun if set), then resend from the first request that got
//   no reply."
//
//   1) The subordinate is held; R(k) = read 0x20 is sent and is executing (PSEL and
//      PENABLE high). W(k+1) = write 0x22 is sent whole (queued), then R(k+2) =
//      read 0x23 whose 4th byte has a low stop bit. No byte after the framing error
//      is 0x55.
//   2) While held: no response byte, no write on the bus.
//   3) Released: exactly one 5-byte response, R(k)'s (status 0, 0x20's data); in
//      the whole window only R(k)'s transfer reaches the APB (one PSEL rise) and
//      0x22 is never written.
//   4) Recovery: break, 0x80 + echo, DTMSTS read (status 0, depth field), write 1
//      to clear its flag, then 0x22 still holds its seed; the resend of W(k+1) and
//      R(k+2) executes: 0x22 is written exactly once in the whole test and both
//      reads return the expected data.
//----------------------------------------------------------------------------

reg     fq_watch;
integer fq_rise;
integer fq_wr22;

initial begin
   fq_watch = 1'b0;
   fq_rise  = 0;
   fq_wr22  = 0;
end

always @(posedge dmi_psel) if (fq_watch) fq_rise = fq_rise + 1;

// Completed APB writes to DMI register 0x22 (ACCESS with PREADY).
always @(posedge free_clk)
   if (dmi_psel & dmi_penable & dmi_pready & dmi_pwrite & (dmi_paddr[ABITS+1:2] == 7'h22))
      fq_wr22 = fq_wr22 + 1;

task fq_send_byte_ferr;                                   // low stop bit
   input [7:0] b;
   integer i;
   begin
      uart_rx = 1'b0;  #(host_bit_ns);
      for (i = 0; i < 8; i = i + 1) begin
         uart_rx = b[i]; #(host_bit_ns);
      end
      uart_rx = 1'b0;  #(host_bit_ns);                   // framing error
      uart_rx = 1'b1;  #(host_bit_ns);
   end
endtask

task fq_send_req;
   input [ABITS-1:0] addr;
   input [31:0]      data;
   input [1:0]       op;
   begin
      uart_send_byte(8'h55);
      uart_send_byte({{(8-ABITS){1'b0}}, addr});
      uart_send_byte(data[31:24]);
      uart_send_byte(data[23:16]);
      uart_send_byte(data[15:8]);
      uart_send_byte(data[7:0]);
      uart_send_byte({6'b0, op});
   end
endtask

initial
   begin : test
      reg [1:0]  st;
      reg [31:0] rd;
      reg [7:0]  s, b3, b2, b1, b0;

      dtm_init;                                           // 0x80 sync + echo
      slave_latency = 1;
      dmi_uart(7'h20, OP_WRITE, 32'hC0DE_0020, st, rd);
      dmi_uart(7'h22, OP_WRITE, 32'h0BAD_0022, st, rd);
      dmi_uart(7'h23, OP_WRITE, 32'h0A0B_0023, st, rd);
      check_eq("seed_wr22", fq_wr22, 1);
      fq_wr22 = 0;

      $display(" ===============================================");
      $display("|  R(k) held, W(k+1) queued, R(k+2) misframed   |");
      $display(" ===============================================");
      slave_hold = 1'b1;
      fq_rise  = 0;
      fq_watch = 1'b1;
      fq_send_req(7'h20, 32'h0, OP_READ);                 // R(k)
      #(4.0 * host_bit_ns);
      check_eq("Rk_on_bus", {dmi_psel, dmi_penable}, 2'b11);
      fq_send_req(7'h22, 32'hA1B2_C3D4, OP_WRITE);        // W(k+1), queued
      uart_send_byte(8'h55);                              // R(k+2)
      uart_send_byte(8'h23);
      uart_send_byte(8'h00);
      fq_send_byte_ferr(8'hA6);                           // framing error
      uart_send_byte(8'h00);
      uart_send_byte(8'h00);
      uart_send_byte({6'b0, OP_READ});
      #(40.0 * host_bit_ns);
      check_eq("held_no_resp", (rx_wr - rx_rd) & 255, 0);
      check_eq("held_no_wr22", fq_wr22, 0);
      check_eq("held_one_psel", fq_rise, 1);

      slave_hold = 1'b0;
      #(120.0 * host_bit_ns);
      check_eq("resp_bytes", (rx_wr - rx_rd) & 255, 5);
      fifo_pop(s); fifo_pop(b3); fifo_pop(b2); fifo_pop(b1); fifo_pop(b0);
      check_eq("Rk_status", s, 8'h00);
      check_eq("Rk_rdata",  {b3, b2, b1, b0}, 32'hC0DE_0020);
      check_eq("no_wr22", fq_wr22, 0);
      fq_watch = 1'b0;
      check_eq("only_Rk_psel", fq_rise, 1);

      $display(" ===============================================");
      $display("|  Recovery: break, 0x80, DTMSTS, resend        |");
      $display(" ===============================================");
      uart_break;
      uart_autobaud_sync;
      dmi_uart(7'h7F, OP_READ, 32'h0, st, rd);            // DTMSTS
      check_eq("dtmsts_st",    st,       OP_SUCCESS);
      check_eq("dtmsts_depth", rd[15:8], `UART_FIFO_DEPTH);
      dmi_uart(7'h7F, OP_WRITE, 32'h1, st, rd);           // clear rx_overrun if set
      check_eq("dtmsts_clr_st", st, OP_SUCCESS);
      dmi_uart(7'h7F, OP_READ, 32'h0, st, rd);
      check_eq("dtmsts_clear", rd[0], 1'b0);

      dmi_uart(7'h22, OP_READ, 32'h0, st, rd);            // W(k+1) never executed
      check_eq("pre_resend_22", rd, 32'h0BAD_0022);
      check_eq("pre_resend_wr", fq_wr22, 0);

      dmi_uart(7'h22, OP_WRITE, 32'hA1B2_C3D4, st, rd);   // resend W(k+1)
      check_eq("Wk1_status", st, OP_SUCCESS);
      dmi_uart(7'h23, OP_READ, 32'h0, st, rd);            // resend R(k+2)
      check_eq("Rk2_status", st, OP_SUCCESS);
      check_eq("Rk2_rdata",  rd, 32'h0A0B_0023);
      dmi_uart(7'h22, OP_READ, 32'h0, st, rd);
      check_eq("rd22_status", st, OP_SUCCESS);
      check_eq("rd22_rdata",  rd, 32'hA1B2_C3D4);
      repeat (20) @(posedge free_clk);
      check_eq("wr22_once", fq_wr22, 1);

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
