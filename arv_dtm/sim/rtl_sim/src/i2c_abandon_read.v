//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    i2c_abandon_read
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2c_abandon_read
// Module Description : A cleanly ABANDONED response must resync the interpreter.
//
//   Distinct from i2c_read_wedge, which abandons a read mid-BYTE and relies on the
//   read-side watchdog to free the bus. Here the host abandons POLITELY -- it NACKs
//   after 2 of the 5 response bytes and issues a STOP -- so the PHY returns to idle,
//   the watchdog never runs, and nothing aborts arv_dtm_cmd.
//
//   Without a STOP-triggered resync the interpreter stays parked in S_RESP with a
//   part-way txcnt: every later request byte is dropped (rx_take is 0 outside
//   S_SYNC/S_RX, so the FIFO fills and can overrun) and the NEXT read is served the
//   STALE TAIL of the abandoned response.
//
//   A repeated START must NOT do this -- it legitimately separates a request from
//   its response. Only a terminating STOP means "the host gave up", which is why
//   the PHY hands arv_dtm_cmd a separate frame_stop_i.
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

      // Two DISTINCT sentinels so a stale-tail response is unambiguous.
      dmi_i2c(7'h10, OP_WRITE, 32'hC0DE_1234, st, rd);
      dmi_i2c(7'h11, OP_WRITE, 32'hBEEF_5678, st, rd);

      $display(" ===============================================");
      $display("|   Abandon a read after 2 of 5 bytes + STOP    |");
      $display(" ===============================================");

      // ---- request phase: read 0x10 ----
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b0}, ack);    // addr + W
      i2c_write_byte(8'h55, ack);               // SYNC
      i2c_write_byte({1'b0, 7'h10}, ack);       // DMI address
      i2c_write_byte(8'h00, ack);               // data [31:24]
      i2c_write_byte(8'h00, ack);               // data [23:16]
      i2c_write_byte(8'h00, ack);               // data [15:8]
      i2c_write_byte(8'h00, ack);               // data [7:0]
      i2c_write_byte(8'h01, ack);               // op = READ

      // ---- response phase: take only 2 of 5 bytes, then NACK + STOP ----
      i2c_start;                                // repeated START (must NOT resync)
      i2c_write_byte({I2C_ADDR, 1'b1}, ack);    // addr + R
      i2c_read_byte(b, 1'b1);                   // byte 0 (status) -- ACK
      check_eq("abandon_st", b, 8'h00);         // the op itself succeeded
      i2c_read_byte(b, 1'b0);                   // byte 1 -- NACK: give up here
      i2c_stop;                                 // terminating STOP -> must resync

      $display(" ===============================================");
      $display("|   Next transaction is clean (no stale tail)   |");
      $display(" ===============================================");

      // A fresh, unrelated transaction must behave normally. A DTM still parked in
      // S_RESP would hand back the abandoned response's remaining bytes instead.
      dmi_i2c(7'h11, OP_READ, 32'h0, st, rd);
      check_eq("post_abandon_st", st, OP_SUCCESS);
      check_eq("post_abandon_rd", rd, 32'hBEEF_5678);   // NOT 0x10's stale tail

      // ... and the link stays usable.
      dmi_i2c(7'h10, OP_READ, 32'h0, st, rd);
      check_eq("still_alive", rd, 32'hC0DE_1234);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
