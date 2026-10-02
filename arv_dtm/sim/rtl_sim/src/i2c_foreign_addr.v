//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    i2c_foreign_addr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2c_foreign_addr
// Module Description : Traffic addressed to ANOTHER target must be ignored completely:
//                      no ACK, no bus drive, no DMI op.
//
//   I2C is a SHARED bus. Every other i2c_* test addresses this target, so a decoder
//   that matched any address -- or ACKed unconditionally -- looked identical to a
//   correct one. It is not: a target that ACKs a foreign address corrupts the real
//   target's transfer, and one that runs the frame will execute someone else's bytes
//   as DMI operations.
//
//   The frame driven here is a complete, well-formed write to a DIFFERENT address,
//   carrying a payload that would be a legal DMI write if it were ever decoded. Three
//   things are then required: the address byte is NACKed, the target never pulls SDA
//   for the rest of the frame, and the DM's memory is untouched.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [1:0]  st;
      reg [31:0] rd;
      reg        ack;
      reg        drove;
      integer    i;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      $display(" ===================================================");
      $display("|  I2C: a frame for another target is ignored       |");
      $display(" ===================================================");

      // Seed a known value through the real address, so a stray foreign-frame write
      // has something recognisable to corrupt.
      dmi_i2c(7'h12, OP_WRITE, 32'hA5A5_1234, st, rd);
      dmi_i2c(7'h12, OP_READ,  32'h0,         st, rd);
      check_eq("seed_rd", rd, 32'hA5A5_1234);

      // -- a complete write frame addressed elsewhere ---------------------------
      // I2C_ADDR is 7'h30; 7'h31 differs in one bit, so this also covers a decoder
      // that compares too few bits.
      drove = 1'b0;
      i2c_start;
      i2c_write_byte({7'h31, 1'b0}, ack);
      check_eq("nack_foreign_addr", {7'd0, ack}, 8'd0);      // target must NOT ACK

      // The payload must be a legal DMI *WRITE* to the seeded address, not just
      // plausible bytes: a decoder that NACKs but still RUNS the frame is only
      // observable through a side effect. (A read payload leaves the DM unchanged and
      // lets `matched = 1'b1` survive -- measured.)
      //   [SYNC][addr=0x12][d31:24..d7:0 = 0xBAD0BAD0][op=2 write]
      for (i = 0; i < 7; i = i + 1) begin
         case (i)
            0 : i2c_write_byte(8'h55, ack);                   // SYNC
            1 : i2c_write_byte(8'h12, ack);                   // the address we seeded
            2 : i2c_write_byte(8'hBA, ack);
            3 : i2c_write_byte(8'hD0, ack);
            4 : i2c_write_byte(8'hBA, ack);
            5 : i2c_write_byte(8'hD0, ack);
            default : i2c_write_byte(8'h02, ack);             // op = write
         endcase
         if (dut_sda_pd) drove = 1'b1;
      end
      i2c_stop;
      check_eq("never_drove_sda", {7'd0, drove}, 8'd0);

      // -- the DM was not touched, and we are still addressable -----------------
      dmi_i2c(7'h12, OP_READ, 32'h0, st, rd);
      check_eq("dm_untouched", rd, 32'hA5A5_1234);

      dmi_i2c(7'h34, OP_WRITE, 32'hDEAD_BEEF, st, rd);
      dmi_i2c(7'h34, OP_READ,  32'h0,         st, rd);
      check_eq("still_addressable", rd, 32'hDEAD_BEEF);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
