//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    i2c_abandon_restart
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2c_abandon_restart
// Module Description : A master that abandons a response with a repeated START --
//                      inside a data byte, or in the ACK slot -- and re-addresses
//                      the target is served at once, without waiting for the
//                      read-side watchdog.
//
//   The documented contract: a START is honoured during the read phase wherever
//   the target has released SDA (a 1 bit, the master's ACK slot). The target must
//   drop the old response, decode the new address, and answer the new request.
//----------------------------------------------------------------------------

reg wd_seen;
initial wd_seen = 1'b0;
always @(posedge free_clk) if (dbgresetn && dut.g_i2c.u_dtm.wd_expired) wd_seen <= 1'b1;   // out of reset only

task send_request;                       // request phase only (START ... op)
   input [6:0]  addr;
   input [1:0]  op;
   reg          ack;
   begin
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b0}, ack);
      i2c_write_byte(8'h55, ack);
      i2c_write_byte({1'b0, addr}, ack);
      i2c_write_byte(8'h00, ack);  i2c_write_byte(8'h00, ack);
      i2c_write_byte(8'h00, ack);  i2c_write_byte(8'h00, ack);
      i2c_write_byte({6'b0, op}, ack);
   end
endtask

task read_bits;                          // clock n bits of the response, no ACK
   input integer n;
   integer i;
   begin
      m_sda_pd = 1'b0;
      for (i = 0; i < n; i = i + 1) begin
         scl_release_high;
         scl_drive_low;
      end
   end
endtask

initial
   begin : test
      reg [31:0] rd;
      reg  [1:0] st;
      reg  [7:0] b;
      reg        ack;
      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      dmi_i2c(7'h12, OP_WRITE, 32'hFFFF_FFFF, st, rd);   // data bytes all ones
      dmi_i2c(7'h13, OP_WRITE, 32'h1357_9BDF, st, rd);

      $display(" ===============================================");
      $display("|  Repeated START inside a response data byte   |");
      $display(" ===============================================");
      send_request(7'h12, OP_READ);
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b1}, ack);
      i2c_read_byte(b, 1'b1);                        // status, ACK
      read_bits(3);                                  // 3 of the 8 one-bits of d31:24
      dmi_i2c(7'h13, OP_READ, 32'h0, st, rd);        // its START abandons the response
      check_eq("mid_byte_status", st, OP_SUCCESS);
      check_eq("mid_byte_rdata",  rd, 32'h1357_9BDF);

      $display(" ===============================================");
      $display("|  Repeated START in the master's ACK slot      |");
      $display(" ===============================================");
      send_request(7'h12, OP_READ);
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b1}, ack);
      read_bits(8);                                  // status, then no ACK: START instead
      dmi_i2c(7'h13, OP_READ, 32'h0, st, rd);
      check_eq("ack_slot_status", st, OP_SUCCESS);
      check_eq("ack_slot_rdata",  rd, 32'h1357_9BDF);

      check_eq("watchdog_not_needed", wd_seen, 1'b0);
      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
