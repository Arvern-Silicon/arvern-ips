//----------------------------------------------------------------------------
// File Name          : i2c_resync_sr_resp
// Module Description : A repeated START that abandons a response must resync the
//                      interpreter -- not leave it parked serving the stale tail.
//
//   The resync override chain covered {STOP, repeated-START} x mid-REQUEST and
//   STOP x mid-RESPONSE. Repeated-START x mid-RESPONSE was the uncovered cell: the
//   FSM stayed in S_RESP with a partial txcnt and the PREVIOUS transaction's data,
//   and served that tail to the next read while dropping the request in between.
//
//   Legal I2C -- a master may retain the bus with a repeated START after a NACK.
//   The guard is txcnt-based, not delimiter-based: txcnt can only leave 0 via a
//   tx_xfer (which needs the read-address ACK), so at the LEGITIMATE
//   request->response repeated START txcnt is provably 0. Any boundary in S_RESP
//   with txcnt != 0 is by construction an abandoned response.
//
//   DISCRIMINATOR: probe arv_dtm_cmd.state immediately after the repeated START -- it
//   must already be back in S_SYNC. Two earlier mistakes both made this pass with the
//   fix REVERTED, so do not reintroduce either:
//     * checking only the next read's DATA -- the read-side watchdog eventually rescues
//       a parked FSM, so a data check passes either way;
//     * reading a SECOND byte after the NACK -- i2c_read_byte's argument is 1=ACK,
//       0=NACK, so that second read ran against an already-idle PHY and its stray
//       SCL/SDA activity generated a delimiter that resynced the FSM by itself.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;
      reg [7:0]  b;
      reg        ack;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      slave_latency = 2;

      dmi_i2c(7'h10, OP_WRITE, 32'hC0DE_1234, st, rd);
      dmi_i2c(7'h11, OP_WRITE, 32'hBEEF_5678, st, rd);

      $display(" ===============================================");
      $display("|  Abandon a response with a repeated START     |");
      $display(" ===============================================");

      // ---- request: read 0x10 ----
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b0}, ack);
      i2c_write_byte(8'h55, ack);
      i2c_write_byte({1'b0, 7'h10}, ack);
      i2c_write_byte(8'h00, ack);
      i2c_write_byte(8'h00, ack);
      i2c_write_byte(8'h00, ack);
      i2c_write_byte(8'h00, ack);
      i2c_write_byte(8'h01, ack);               // op = READ

      // ---- take ONE response byte and NACK it -> txcnt = 1, host gives up ----
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b1}, ack);
      i2c_read_byte(b, 1'b0);                   // ack=0 => NACK (1 would be ACK)

      // ---- repeated START instead of STOP: the uncovered delimiter ----
      i2c_start;
      repeat (8) @(posedge free_clk);

      // The interpreter must already be back in S_SYNC (0). Unpatched it sits in
      // S_RESP (4) with txcnt != 0, holding the previous transaction's tail.
      check_eq("sr_state_resync", {29'd0, dut.g_i2c.u_dtm.u_cmd.state}, 32'd0);

      // ---- a full, well-formed read of the OTHER address ----
      dmi_i2c(7'h11, OP_READ, 32'h0, st, rd);
      check_eq("sr_status", {30'd0, st}, 32'd0);
      check_eq("sr_rdata",  rd,          32'hBEEF_5678);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
