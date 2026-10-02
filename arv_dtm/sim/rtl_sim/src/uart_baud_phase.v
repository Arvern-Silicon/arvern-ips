//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_baud_phase
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_baud_phase
// Module Description : The fast edge of the auto-baud range, at several host
//                      phases against clk_i, with streamed 0xFF- and 0x00-heavy
//                      traffic.
//
//   doc/arv_dtm_uart.md:
//   - Host protocol contract: "Baud: any rate between 16·f_clk/AB_BREAK_CLKS and
//     16 clk_i per bit; the DTM replies at the rate it measured."
//   - Integration requirements: "The fastest host baud exercised by the
//     regression is 16 clk_i per bit; AB_DIV_FLOOR = 2 is the arithmetic limit of
//     the divisor, not a tested operating point."
//   - Request pipelining: "The safe bound is at most 1 + floor(RX_FIFO_DEPTH / 7)
//     requests sent whose responses have not yet been received".
//   - Recovery: "break -> 0x80 -> echo therefore re-establishes the link from
//     anywhere, same baud or not."
//   The contract stops at 16 clk_i per bit (the doc's host baud tolerance explains
//   why), so the two contract rates are asserted first. Two host rates, set exactly
//   (no per-seed jitter): 16.0 clk_i per bit (the documented fastest) and
//   16.5 clk_i per bit (legal, non-integer, just inside the fast edge). A third
//   rate, 15.63 clk_i per bit, is the fast edge of the divisor-16 lock window: it is
//   past the contract and pins the documented margin (doc/arv_dtm_uart.md, host
//   baud tolerance) with 0xFF-heavy words, the worst case for the stop sample. Each rate
//   runs at four sub-cycle phases of the host's bit edges against the clk_i
//   rising edge (1.0 / 3.5 / 6.0 / 8.5 ns; 0 ns avoided, where simulator event
//   order would decide). At 16.0 clk_i per bit every edge of a streamed burst
//   keeps its phase; at 16.5 the phase alternates.
//
//   For each (rate, phase): break (after the first), set the rate, align the
//   0x80 to the phase, lock and check the echo; then, re-aligned, stream
//   NQ = min(4, 1 + UART_FIFO_DEPTH/7) write requests back-to-back (all-ones,
//   all-zeros, single-zero, single-one data words; addresses 0x00/0x7E/0x01/0x7D)
//   and pop every response (status 0); check slave_mem; stream NQ reads of the
//   same addresses and pop them: status 0, data exact, in order.
//----------------------------------------------------------------------------

reg [31:0] bp_pat [0:3];
reg  [6:0] bp_adr [0:3];
initial begin
   bp_pat[0] = 32'hFFFF_FFFF;   bp_adr[0] = 7'h00;
   bp_pat[1] = 32'h0000_0000;   bp_adr[1] = 7'h7E;
   bp_pat[2] = 32'hFEFF_FF7F;   bp_adr[2] = 7'h01;
   bp_pat[3] = 32'h8000_0001;   bp_adr[3] = 7'h7D;
end

task bp_send_req;                        // request frame, response not popped
   input [ABITS-1:0] addr;
   input [1:0]       op;
   input [31:0]      data;
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

task bp_pop_resp;
   output [1:0]  status;
   output [31:0] rdata;
   reg [7:0] s, b3, b2, b1, b0;
   begin
      fifo_pop(s);
      fifo_pop(b3);
      fifo_pop(b2);
      fifo_pop(b1);
      fifo_pop(b0);
      check_eq("resp_st_hi_zero", s[7:2], 6'd0);
      status = s[1:0];
      rdata  = {b3, b2, b1, b0};
   end
endtask

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;
      integer    r, p, k, idx, nq;
      real       rate_clk;
      real       phase_ns;

      nq = 1 + (`UART_FIFO_DEPTH / 7);
      if (nq > 4) nq = 4;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      slave_latency = 0;

      for (r = 0; r < 3; r = r + 1) begin
         rate_clk = (r == 0) ? 16.0 : (r == 1) ? 16.5 : 15.63;
         for (p = 0; p < 4; p = p + 1) begin
            case (p)
               0: phase_ns = 1.0;
               1: phase_ns = 3.5;
               2: phase_ns = 6.0;
               default: phase_ns = 8.5;
            endcase
            $display(" ===============================================");
            $display("|  host %0.2f clk/bit, phase %0.1f ns after clk rise", rate_clk, phase_ns);
            $display(" ===============================================");

            if ((r != 0) || (p != 0))
               uart_break;                                   // unlock; line quiet, host FIFO drained
            host_bit_ns = rate_clk * (FREE_HALF * 2.0);

            @(posedge free_clk); #(phase_ns);
            uart_autobaud_sync;                              // 0x80 at this phase, echo checked

            for (k = 0; k < 4; k = k + 1)
               slave_mem[bp_adr[k]] = 32'h5A5A_A5A5 ^ (r * 8 + p * 2 + k);

            // Streamed writes.
            @(posedge free_clk); #(phase_ns);
            for (k = 0; k < nq; k = k + 1) begin
               idx = (k + p + r) % 4;
               bp_send_req(bp_adr[k], OP_WRITE, bp_pat[idx]);
            end
            for (k = 0; k < nq; k = k + 1) begin
               bp_pop_resp(st, rd);
               check_eq("wr_status", st, OP_SUCCESS);
            end
            for (k = 0; k < nq; k = k + 1) begin
               idx = (k + p + r) % 4;
               check_eq("wr_landed", slave_mem[bp_adr[k]], bp_pat[idx]);
            end

            // Streamed reads.
            @(posedge free_clk); #(phase_ns);
            for (k = 0; k < nq; k = k + 1)
               bp_send_req(bp_adr[k], OP_READ, 32'h0);
            for (k = 0; k < nq; k = k + 1) begin
               idx = (k + p + r) % 4;
               bp_pop_resp(st, rd);
               check_eq("rd_status", st, OP_SUCCESS);
               check_eq("rd_data",   rd, bp_pat[idx]);
            end
         end
      end

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
