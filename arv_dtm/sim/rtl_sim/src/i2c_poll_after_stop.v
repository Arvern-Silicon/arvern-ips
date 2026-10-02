//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    i2c_poll_after_stop
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2c_poll_after_stop
// Module Description : The documented recovery for a STOP-abandoned request: a
//                      new op = 0 (poll) request retrieves the abandoned op's
//                      result.
//
//   doc/arv_dtm_i2c.md, DMI transaction: "A STOP after the request abandons the
//   response: the DMI op still executes (a write takes effect), its result is
//   discarded [...] To retrieve the result of an abandoned op, send a new request
//   with op = 0 and read it by repeated START."
//   Field table: "op ... 0 poll (returns the last completed result, no bus
//   access)". Abandoned-transactions table: "STOP after the complete request,
//   response unread | Op executes; response discarded [...] Retrieve the result
//   with op = 0."
//   DMI transaction: "unless a STOP-abandoned op is still in flight when the
//   repeated START arrives [...] the new request is then lost" -- so the poll is
//   sent only after the held op has visibly completed on the APB bus.
//
//   Each leg: hold the slave, write a request, STOP (no response read), check
//   the op is on the APB bus (dmi_psel high), release the slave, wait for
//   dmi_psel to fall, then poll by a normal request + repeated START read.
//     Leg 1: abandoned READ   -> poll returns status 0 + the read's data;
//            the result differs from the previous completed result.
//     Leg 2: abandoned WRITE  -> the write took effect (slave_mem); poll status 0
//            (a write's response data is undefined, not checked).
//     Leg 3: abandoned failing READ (slave_fault_en) -> poll returns status 2.
//   The poll itself never makes an APB access, and a repeated poll returns the
//   same result. A normal transaction afterwards round-trips.
//----------------------------------------------------------------------------

integer psel_cnt;
initial psel_cnt = 0;
always @(posedge dmi_psel) psel_cnt = psel_cnt + 1;

task pas_send_req;                        // START, {addr,W}, 7-byte request (no read)
   input [6:0]  addr;
   input [1:0]  op;
   input [31:0] data;
   reg          ack;
   reg          all_ack;
   begin
      all_ack = 1'b1;
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b0}, ack);  all_ack = all_ack & ack;
      i2c_write_byte(8'h55, ack);             all_ack = all_ack & ack;
      i2c_write_byte({1'b0, addr}, ack);      all_ack = all_ack & ack;
      i2c_write_byte(data[31:24], ack);       all_ack = all_ack & ack;
      i2c_write_byte(data[23:16], ack);       all_ack = all_ack & ack;
      i2c_write_byte(data[15:8],  ack);       all_ack = all_ack & ack;
      i2c_write_byte(data[7:0],   ack);       all_ack = all_ack & ack;
      i2c_write_byte({6'b0, op},  ack);       all_ack = all_ack & ack;
      check_eq("req_all_acked", all_ack, 1'b1);
   end
endtask

// Abandon a request with STOP while the slave is held, then let the op complete.
task pas_abandon;
   input [6:0]  addr;
   input [1:0]  op;
   input [31:0] data;
   begin
      slave_hold = 1'b1;
      pas_send_req(addr, op, data);
      repeat (40) @(posedge free_clk);
      check_eq("op_on_bus", dmi_psel, 1'b1);           // launched, held in ACCESS
      i2c_stop;                                        // abandon: no response read
      repeat (200) @(posedge free_clk);                // well after the STOP
      check_eq("still_held", dmi_psel, 1'b1);
      slave_hold = 1'b0;
      wait (dmi_psel === 1'b0);                        // op completed on the bus
      repeat (40) @(posedge free_clk);
   end
endtask

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;
      integer    pc;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      slave_latency = 0;

      dmi_i2c(7'h11, OP_WRITE, 32'h5EED_1111, st, rd);   // the abandoned read's value
      dmi_i2c(7'h12, OP_WRITE, 32'h0DDB_A112, st, rd);
      dmi_i2c(7'h12, OP_READ,  32'h0,         st, rd);   // last completed result = 0x0DDBA112
      check_eq("prime_rd", rd, 32'h0DDB_A112);

      $display(" ===============================================");
      $display("|  Leg 1: abandoned READ, result by poll        |");
      $display(" ===============================================");
      pas_abandon(7'h11, OP_READ, 32'h0);
      pc = psel_cnt;
      dmi_i2c(7'h00, OP_NOP, 32'h0, st, rd);
      check_eq("l1_poll_st",   st, OP_SUCCESS);
      check_eq("l1_poll_rd",   rd, 32'h5EED_1111);      // the abandoned read's data
      check_eq("l1_no_psel",   psel_cnt - pc, 0);
      dmi_i2c(7'h00, OP_NOP, 32'h0, st, rd);            // repeatable
      check_eq("l1_poll2_st",  st, OP_SUCCESS);
      check_eq("l1_poll2_rd",  rd, 32'h5EED_1111);
      check_eq("l1_no_psel2",  psel_cnt - pc, 0);

      $display(" ===============================================");
      $display("|  Leg 2: abandoned WRITE takes effect          |");
      $display(" ===============================================");
      pas_abandon(7'h13, OP_WRITE, 32'hC0FF_EE13);
      check_eq("l2_write_done", slave_mem[7'h13], 32'hC0FF_EE13);
      pc = psel_cnt;
      dmi_i2c(7'h00, OP_NOP, 32'h0, st, rd);
      check_eq("l2_poll_st",   st, OP_SUCCESS);
      check_eq("l2_no_psel",   psel_cnt - pc, 0);
      dmi_i2c(7'h13, OP_READ, 32'h0, st, rd);
      check_eq("l2_readback",  rd, 32'hC0FF_EE13);

      $display(" ===============================================");
      $display("|  Leg 3: abandoned failing READ -> status 2    |");
      $display(" ===============================================");
      slave_fault_en   = 1'b1;
      slave_fault_addr = 7'h14;
      pas_abandon(7'h14, OP_READ, 32'h0);
      slave_fault_en   = 1'b0;
      pc = psel_cnt;
      dmi_i2c(7'h00, OP_NOP, 32'h0, st, rd);
      check_eq("l3_poll_st",   st, OP_FAILED);
      check_eq("l3_no_psel",   psel_cnt - pc, 0);

      $display(" ===============================================");
      $display("|  Normal transaction afterwards                |");
      $display(" ===============================================");
      dmi_i2c(7'h15, OP_WRITE, 32'hA5A5_5A5A, st, rd);
      check_eq("post_wr_st",   st, OP_SUCCESS);
      dmi_i2c(7'h15, OP_READ,  32'h0,         st, rd);
      check_eq("post_rd_st",   st, OP_SUCCESS);
      check_eq("post_rd",      rd, 32'hA5A5_5A5A);
      dmi_i2c(7'h11, OP_READ,  32'h0,         st, rd);
      check_eq("post_rd11",    rd, 32'h5EED_1111);

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
