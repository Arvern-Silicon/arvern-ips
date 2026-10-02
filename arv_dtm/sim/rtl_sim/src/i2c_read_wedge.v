//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    i2c_read_wedge
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2c_read_wedge.v
// Module Description : A pure HOST fault on the read side must not wedge the
//                      shared I2C bus forever.
//
//   Part A -- over-read (ST_READ_LOAD, SCL held low): the host ACKs the last
//   (5th) response byte and clocks a 6th. The target re-enters ST_READ_LOAD to
//   fetch a byte arv_dtm_cmd will never produce, and clock-stretches SCL low
//   forever. Without the read-side watchdog the 6th read never completes.
//
//   Part B -- abandoned read (ST_READ, SDA held low): the host clocks a couple
//   of bits of a response byte (status = 0x00, so the target drives SDA low) and
//   then stops. Without the watchdog the target holds SDA low forever.
//
//   Each part is checked against a bounded window (> the ~2^16-cycle watchdog,
//   < any host give-up): the read-side watchdog must release the bus and recover
//   within it; a DUT that does not stays wedged and the part logs an error. Bus ops
//   after a detected wedge are skipped -- on a wedged DUT they would themselves hang
//   on the held-low SCL.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [1:0]  st;
      reg [31:0] rd;
      reg        ack;
      reg [7:0]  s, b3, b2, b1, b0, b6;
      reg        rbit;
      reg        recovered;

      // Recovery window (ns): comfortably above the read-side watchdog (2^16
      // clk_i = ~655 us at 100 MHz) and below any realistic host timeout.

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      // Seed a known value so the read response (and its status = success) is
      // deterministic.
      dmi_i2c(7'h10, OP_WRITE, 32'hC0DE_1234, st, rd);
      dmi_i2c(7'h10, OP_READ,  32'h0,         st, rd);
      check_eq("seed_rd", rd, 32'hC0DE_1234);

      $display(" ===============================================");
      $display("|  Part A: over-read must not wedge SCL low     |");
      $display(" ===============================================");

      // ---- read request (write phase, op = READ) ----
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b0}, ack);            // addr + W
      i2c_write_byte(8'h55, ack);                       // SYNC
      i2c_write_byte({1'b0, 7'h10}, ack);               // DMI address
      i2c_write_byte(8'h00, ack);
      i2c_write_byte(8'h00, ack);
      i2c_write_byte(8'h00, ack);
      i2c_write_byte(8'h00, ack);
      i2c_write_byte({6'b0, OP_READ}, ack);             // op = read

      // ---- response (repeated-START, read) -- ACK ALL 5 bytes (the over-read) ----
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b1}, ack);            // addr + R
      i2c_read_byte(s,  1'b1);                          // status  ACK
      i2c_read_byte(b3, 1'b1);                          // d31:24  ACK
      i2c_read_byte(b2, 1'b1);                          // d23:16  ACK
      i2c_read_byte(b1, 1'b1);                          // d15:8   ACK
      i2c_read_byte(b0, 1'b1);                          // d7:0    ACK  <-- one too many

      // 6th read: the target re-enters ST_READ_LOAD and stretches SCL. Bounded
      // wait -- the watchdog must release it so the read completes.
      recovered = 1'b0;
      fork
         begin : rd6
            i2c_read_byte(b6, 1'b0);
            recovered = 1'b1;
            `FORK_KILL(guardA)
         end
         begin : guardA
            #800000;
            $display("ERROR: SCL wedged after over-read (no read-side watchdog)  %0t ns", $time);
            error = error + 1;
            `FORK_KILL(rd6)
         end
      `JOIN_FIRST

      if (recovered) begin
         i2c_stop;                                      // now possible: SCL released

         // The over-read completed the 5-byte response, so arv_dtm_cmd is back at
         // S_SYNC -- a fresh transaction returns the correct value: the bus (and
         // the interpreter) fully recovered.
         dmi_i2c(7'h10, OP_READ, 32'h0, st, rd);
         check_eq("postA_st", st, OP_SUCCESS);
         check_eq("postA_rd", rd, 32'hC0DE_1234);

         $display(" ===============================================");
         $display("|  Part B: abandoned read must not wedge SDA    |");
         $display(" ===============================================");

         // ---- read request again ----
         i2c_start;
         i2c_write_byte({I2C_ADDR, 1'b0}, ack);
         i2c_write_byte(8'h55, ack);
         i2c_write_byte({1'b0, 7'h10}, ack);
         i2c_write_byte(8'h00, ack);
         i2c_write_byte(8'h00, ack);
         i2c_write_byte(8'h00, ack);
         i2c_write_byte(8'h00, ack);
         i2c_write_byte({6'b0, OP_READ}, ack);

         // ---- response: clock only 2 bits of the status byte, then abandon ----
         i2c_start;
         i2c_write_byte({I2C_ADDR, 1'b1}, ack);         // addr + R
         m_sda_pd = 1'b0;                               // release SDA (target drives)
         scl_release_high; rbit = sda; scl_drive_low;   // status bit 7 (=0)
         scl_release_high; rbit = sda; scl_drive_low;   // status bit 6 (=0)
         // Abandon: SCL is now held low by the master; stop clocking. The target
         // is in ST_READ driving SDA low (status MSBs are 0) -> dut_sda_pd = 1.
         // The watchdog must release the held SDA. (Re-synchronising the mid-
         // response interpreter is a separate concern -- see i2c_frame_resync.)

         recovered = 1'b0;
         fork
            begin : sdaw
               wait (dut_sda_pd === 1'b0);              // watchdog releases the hold
               recovered = 1'b1;
               `FORK_KILL(guardB)
            end
            begin : guardB
               #800000;
               $display("ERROR: SDA wedged after abandoned read (no read-side watchdog)  %0t ns", $time);
               error = error + 1;
               `FORK_KILL(sdaw)
            end
         `JOIN_FIRST

         if (recovered) begin
            m_scl_pd = 1'b0;  #(T_HIGH);               // master releases SCL
            i2c_stop;                                   // re-idle the bus
         end
      end

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
