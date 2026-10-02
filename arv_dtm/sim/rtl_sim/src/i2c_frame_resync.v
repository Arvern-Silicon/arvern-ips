//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    i2c_frame_resync
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2c_frame_resync
// Module Description : A truncated or abandoned I2C frame must NOT strand the byte
//                      interpreter mid-transaction.
//
//   The "DMI over serial" frame is fixed-length and checksum-free. Without a
//   PHY->cmd resync a partial frame leaves arv_dtm_cmd mid-parse, so the *next*
//   frame's SYNC lands in a payload slot and is silently mis-decoded -- which can
//   fire a spurious DMI write. The I2C PHY snaps cmd back to SYNC on a frame
//   boundary (STOP / repeated-START, while a request is still being received) and
//   on a hard abort (the read-side watchdog, for an abandoned read).
//
//   Part A -- request truncated by STOP.
//   Part B -- request truncated by a repeated-START that begins a fresh frame.
//   Part C -- read abandoned mid-response (watchdog abort resyncs cmd).
//   In every case the FOLLOWING transaction must return the correct seeded value.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [1:0]  st;
      reg [31:0] rd;
      reg        ack;
      reg        rbit;
      reg        recovered;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      // Two DISTINCT seeds. A desync typically aliases the follow-up read into a
      // NOP that polls the LAST completed result, so each part first reads 0x20
      // (priming that stale value to 0xBEEF5678) -- then a mis-parsed read of 0x10
      // returns the wrong 0xBEEF5678, while a correctly re-synced one returns
      // 0xC0DE1234.
      dmi_i2c(7'h10, OP_WRITE, 32'hC0DE_1234, st, rd);
      dmi_i2c(7'h20, OP_WRITE, 32'hBEEF_5678, st, rd);
      dmi_i2c(7'h10, OP_READ,  32'h0,         st, rd);
      check_eq("seed_rd", rd, 32'hC0DE_1234);

      $display(" ===============================================");
      $display("|  Part A: request truncated by STOP            |");
      $display(" ===============================================");

      dmi_i2c(7'h20, OP_READ, 32'h0, st, rd);               // prime stale result = 0xBEEF5678

      // Partial request (SYNC + addr + one data byte), then STOP.
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b0}, ack);                // addr + W
      i2c_write_byte(8'h55, ack);                           // SYNC
      i2c_write_byte({1'b0, 7'h10}, ack);                   // DMI address
      i2c_write_byte(8'hAA, ack);                           // d31:24 -- then truncate
      i2c_stop;                                             // STOP -> resync cmd

      dmi_i2c(7'h10, OP_READ, 32'h0, st, rd);               // next frame must parse cleanly
      check_eq("stopA_st", st, OP_SUCCESS);
      check_eq("stopA_rd", rd, 32'hC0DE_1234);

      $display(" ===============================================");
      $display("|  Part B: request truncated by repeated-START  |");
      $display(" ===============================================");

      dmi_i2c(7'h20, OP_READ, 32'h0, st, rd);               // prime stale result = 0xBEEF5678

      // Partial request with NO stop; the next transaction's START is the
      // repeated-START that truncates it and must resync cmd.
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b0}, ack);                // addr + W
      i2c_write_byte(8'h55, ack);                           // SYNC
      i2c_write_byte({1'b0, 7'h20}, ack);                   // addr -- then truncate (no more bytes)

      dmi_i2c(7'h10, OP_READ, 32'h0, st, rd);               // its START truncates + resyncs
      check_eq("startB_st", st, OP_SUCCESS);
      check_eq("startB_rd", rd, 32'hC0DE_1234);

      $display(" ===============================================");
      $display("|  Part C: read abandoned mid-response          |");
      $display(" ===============================================");

      dmi_i2c(7'h20, OP_READ, 32'h0, st, rd);               // prime stale result = 0xBEEF5678

      // Full read request, then abandon after 2 response bits -> cmd is left in
      // S_RESP with bytes pending; the watchdog abort must resync it.
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b0}, ack);
      i2c_write_byte(8'h55, ack);
      i2c_write_byte({1'b0, 7'h10}, ack);
      i2c_write_byte(8'h00, ack);
      i2c_write_byte(8'h00, ack);
      i2c_write_byte(8'h00, ack);
      i2c_write_byte(8'h00, ack);
      i2c_write_byte({6'b0, OP_READ}, ack);

      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b1}, ack);                // addr + R
      m_sda_pd = 1'b0;                                      // release SDA (target drives)
      scl_release_high; rbit = sda; scl_drive_low;          // status bit 7
      scl_release_high; rbit = sda; scl_drive_low;          // status bit 6
      // Abandon: SCL held low by the master; wait past the read-side watchdog.

      recovered = 1'b0;
      fork
         begin : sdaw
            wait (dut_sda_pd === 1'b0);                     // watchdog releases + aborts cmd
            recovered = 1'b1;
            `FORK_KILL(guardC)
         end
         begin : guardC
            #800000;
            $display("ERROR: read stayed wedged (no watchdog)  %0t ns", $time);
            error = error + 1;
            `FORK_KILL(sdaw)
         end
      `JOIN_FIRST

      if (recovered) begin
         m_scl_pd = 1'b0;  #(T_HIGH);
         i2c_stop;
         dmi_i2c(7'h10, OP_READ, 32'h0, st, rd);            // must be re-synced, not byte-shifted
         check_eq("abandC_st", st, OP_SUCCESS);
         check_eq("abandC_rd", rd, 32'hC0DE_1234);
      end

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
