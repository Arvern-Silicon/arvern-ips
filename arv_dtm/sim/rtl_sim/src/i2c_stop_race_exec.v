//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    i2c_stop_race_exec
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2c_stop_race_exec
// Module Description : A STOP that abandons a queued poll request lands in the
//                      cycle the command layer executes it.
//
//   With the DMI slave held, the host abandons a read request with a STOP, then
//   writes a whole op = 0 (poll) request, which queues in the RX FIFO behind the
//   held op, and abandons that one too with a STOP. The slave is released at a
//   swept offset around the second STOP, so one offset makes the queued poll
//   reach execution in the STOP's cycle. The command layer must drop the
//   abandoned poll's response and return to S_SYNC: the next, normal
//   transaction must receive its own data with SUCCESS, never a stale response.
//----------------------------------------------------------------------------

integer d;

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;
      reg        ack;
      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      slave_latency = 0;
      dmi_i2c(7'h11, OP_WRITE, 32'hABAD_0000, st, rd);    // the abandoned read's value
      dmi_i2c(7'h12, OP_WRITE, 32'h600D_1234, st, rd);    // the next read's value
      $display(" ===============================================");
      $display("|  STOP abandoning a queued poll vs its exec    |");
      $display(" ===============================================");
      for (d = 0; d < 48; d = d + 1) begin
         slave_hold = 1'b1;
         i2c_start;                                       // read request, abandoned
         i2c_write_byte({I2C_ADDR, 1'b0}, ack);
         i2c_write_byte(8'h55, ack);
         i2c_write_byte(8'h11, ack);
         i2c_write_byte(8'h00, ack);  i2c_write_byte(8'h00, ack);
         i2c_write_byte(8'h00, ack);  i2c_write_byte(8'h00, ack);
         i2c_write_byte({6'b0, OP_READ}, ack);
         repeat (40) @(posedge free_clk);                 // the op is launched and held
         i2c_stop;
         i2c_start;                                       // poll request, queued
         i2c_write_byte({I2C_ADDR, 1'b0}, ack);
         i2c_write_byte(8'h55, ack);
         i2c_write_byte(8'h00, ack);
         i2c_write_byte(8'h00, ack);  i2c_write_byte(8'h00, ack);
         i2c_write_byte(8'h00, ack);  i2c_write_byte(8'h00, ack);
         i2c_write_byte({6'b0, OP_NOP}, ack);
         fork
            begin : releaser
               repeat (d) @(posedge free_clk);
               slave_hold = 1'b0;
            end
            i2c_stop;                                     // abandon the poll
         join
         repeat (60) @(posedge free_clk);
         if (dut.g_i2c.u_dtm.u_cmd.state != 0) $display("offset d=%0d", d);
         check_eq("cmd_back_in_sync", dut.g_i2c.u_dtm.u_cmd.state, 0);
         dmi_i2c(7'h12, OP_READ, 32'h0, st, rd);
         check_eq("next_status", st, OP_SUCCESS);
         check_eq("next_rdata", rd, 32'h600D_1234);
      end
      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
