//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    i2c_stop_race_wait
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2c_stop_race_wait
// Module Description : A STOP that abandons a request lands in the same clk_i
//                      cycle as the DMI completion.
//
//   With the DMI slave held, the host writes a read request and then gives up
//   with a STOP instead of the repeated START. The slave is released at a swept
//   offset around the STOP, so one offset makes the completion (inflight falling
//   in S_WAIT) coincide with frame_stop. The command layer must still drop the
//   abandoned response and return to S_SYNC: the next, normal transaction must
//   receive its own data with SUCCESS, never the abandoned read's value.
//----------------------------------------------------------------------------

integer d;
reg     releasing;

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
      $display("|  STOP abandoning a request vs DMI completion |");
      $display(" ===============================================");
      for (d = 0; d < 25; d = d + 1) begin      // spans completion before, at and after the STOP
         slave_hold = 1'b1;
         releasing  = 1'b0;
         i2c_start;
         i2c_write_byte({I2C_ADDR, 1'b0}, ack);
         i2c_write_byte(8'h55, ack);
         i2c_write_byte(8'h11, ack);
         i2c_write_byte(8'h00, ack);  i2c_write_byte(8'h00, ack);
         i2c_write_byte(8'h00, ack);  i2c_write_byte(8'h00, ack);
         i2c_write_byte({6'b0, OP_READ}, ack);
         repeat (40) @(posedge free_clk);                    // the op is launched and held
         fork
            begin : releaser
               @(posedge dut.g_i2c.u_dtm.scl_lvl);            // the STOP's SCL rise
               repeat (d) @(posedge free_clk);
               slave_hold = 1'b0;
            end
            i2c_stop;                                        // abandon: STOP, no response read
         join
         repeat (60) @(posedge free_clk);
         check_eq("cmd_back_in_sync", dut.g_i2c.u_dtm.u_cmd.state, 0);
         dmi_i2c(7'h12, OP_READ, 32'h0, st, rd);
         check_eq("next_status", st, OP_SUCCESS);
         check_eq("next_rdata", rd, 32'h600D_1234);
      end
      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
