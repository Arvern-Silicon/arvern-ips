//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_dmi_fail
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_dmi_fail
// Module Description : A DMI access the subordinate fails is reported as status 2
//                      in the UART response, the status returns to 0 on the next
//                      successful access, and busy is never reported.
//
//   doc/arv_dtm_uart.md: "status is 0 (success) or 2 (failed, DM raised PSLVERR);
//   busy is never returned"; "Bits [7:2] are 0". "op = 0 (poll): The last completed
//   DMI result (status and data) is returned without a bus access"; "A poll returns
//   the last completed DMI result; neither a DTMSTS access nor a dmihardreset changes
//   it." DTMSTS and op = 3 answer status 0 locally. "The response is held until the
//   DMI access completes, so the host never sees a busy code".
//
//   The full status byte is checked (8'h02 / 8'h00). A failed read and a failed write
//   report 2; polls, a DTMSTS read and an op = 3 in between leave the polled result at
//   2 and reach no bus; a successful read then reports 0 with its data and the poll
//   follows it. A failing read held by the subordinate produces no response byte until
//   released, then status 2.
//----------------------------------------------------------------------------

integer uf_psel;
initial uf_psel = 0;
always @(posedge dmi_psel) uf_psel = uf_psel + 1;

task uf_req;
   input [6:0]  addr;
   input [1:0]  op;
   input [31:0] data;
   begin
      uart_send_byte(8'h55);
      uart_send_byte({1'b0, addr});
      uart_send_byte(data[31:24]);
      uart_send_byte(data[23:16]);
      uart_send_byte(data[15:8]);
      uart_send_byte(data[7:0]);
      uart_send_byte({6'b0, op});
   end
endtask

task uf_rsp;
   output [7:0]  st;
   output [31:0] rd;
   reg [7:0] b3, b2, b1, b0;
   begin
      fifo_pop(st);
      fifo_pop(b3);
      fifo_pop(b2);
      fifo_pop(b1);
      fifo_pop(b0);
      rd = {b3, b2, b1, b0};
   end
endtask

task uf_txn;
   input  [6:0]  addr;
   input  [1:0]  op;
   input  [31:0] data;
   output [7:0]  st;
   output [31:0] rd;
   begin
      uf_req(addr, op, data);
      uf_rsp(st, rd);
   end
endtask

initial
   begin : test
      reg [7:0]  st;
      reg [31:0] rd;
      reg [31:0] frd;
      integer    p0;
      integer    k;

      dtm_init;
      slave_latency = 1;
      slave_mem[7'h24] = 32'h2424_A5A5;
      slave_mem[7'h25] = 32'h1357_9BDF;
      slave_mem[7'h26] = 32'hC3C3_0F0F;

      $display(" ===================================================");
      $display("|  UART: failed status reported, then success again |");
      $display(" ===================================================");
      p0 = uf_psel;
      uf_txn(7'h25, OP_READ, 32'h0, st, rd);
      check_eq("ok_st",   st, 8'h00);
      check_eq("ok_data", rd, 32'h1357_9BDF);
      check_eq("ok_one_psel", uf_psel - p0, 1);

      slave_fault_en   = 1'b1;
      slave_fault_addr = 7'h24;

      p0 = uf_psel;
      uf_txn(7'h24, OP_READ, 32'h0, st, frd);
      check_eq("fail_rd_st", st, 8'h02);
      check_eq("fail_rd_one_psel", uf_psel - p0, 1);

      p0 = uf_psel;
      uf_txn(7'h00, OP_NOP, 32'h0, st, rd);
      check_eq("poll_fail_st",   st, 8'h02);
      check_eq("poll_fail_data", rd, frd);

      uf_txn(7'h7F, OP_READ, 32'h0, st, rd);
      check_eq("dtmsts_st", st, 8'h00);
      uf_txn(7'h00, OP_NOP, 32'h0, st, rd);
      check_eq("poll_after_dtmsts_st",   st, 8'h02);
      check_eq("poll_after_dtmsts_data", rd, frd);

      uf_txn(7'h00, OP_HRST, 32'h0, st, rd);
      check_eq("hrst_st",   st, 8'h00);
      check_eq("hrst_data", rd, 32'h0);
      uf_txn(7'h00, OP_NOP, 32'h0, st, rd);
      check_eq("poll_after_hrst_st",   st, 8'h02);
      check_eq("poll_after_hrst_data", rd, frd);
      check_eq("local_ops_no_psel", uf_psel - p0, 0);

      p0 = uf_psel;
      uf_txn(7'h24, OP_WRITE, 32'h5555_AAAA, st, rd);
      check_eq("fail_wr_st", st, 8'h02);
      check_eq("fail_wr_one_psel", uf_psel - p0, 1);

      p0 = uf_psel;
      uf_txn(7'h26, OP_READ, 32'h0, st, rd);
      check_eq("back_ok_st",   st, 8'h00);
      check_eq("back_ok_data", rd, 32'hC3C3_0F0F);
      uf_txn(7'h00, OP_NOP, 32'h0, st, rd);
      check_eq("poll_ok_st",   st, 8'h00);
      check_eq("poll_ok_data", rd, 32'hC3C3_0F0F);
      check_eq("back_ok_one_psel", uf_psel - p0, 1);

      $display(" ===================================================");
      $display("|  UART: a held failing access is never busy        |");
      $display(" ===================================================");
      slave_hold = 1'b1;
      p0 = uf_psel;
      uf_req(7'h24, OP_READ, 32'h0);
      for (k = 0; k < 40; k = k + 1) begin
         #(host_bit_ns);
         if (rx_wr !== rx_rd) begin
            $display("ERROR: response byte while the access is held  %0t ns", $time);
            error = error + 1;
         end
      end
      check_eq("held_psel", {31'd0, dmi_psel}, 32'd1);
      slave_hold = 1'b0;
      uf_rsp(st, rd);
      check_eq("held_fail_st", st, 8'h02);
      check_eq("held_one_psel", uf_psel - p0, 1);

      uf_txn(7'h25, OP_READ, 32'h0, st, rd);
      check_eq("final_ok_st",   st, 8'h00);
      check_eq("final_ok_data", rd, 32'h1357_9BDF);

      slave_fault_en = 1'b0;
      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
