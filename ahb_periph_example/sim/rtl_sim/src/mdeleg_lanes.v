//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mdeleg_lanes
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mdeleg_lanes.v
// Module Description : MDELEG sub-word writes are byte-lane qualified: a half-word
//                      at 0x40 updates WR_PRIV, RD_PRIV and RESP; a byte at 0x40
//                      updates WR_PRIV and RD_PRIV only; a byte at 0x41 updates
//                      RESP only; lanes 2/3 hold reserved bits only. Every write
//                      starts from a state that a lane-ignoring write would
//                      change; the reserved code 2'b10 reads back as 2'b11 in
//                      each field on its own. A pipelined MDELEG write is in
//                      force for the very next transfer: an MDELEG read returns
//                      the new value, and an access the new gates admit or deny
//                      gets the matching response.
//----------------------------------------------------------------------------

localparam REGOUT_00 = 32'h00400000;
localparam MDELEG    = 32'h00400040;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk);

      $display("");
      $display(" ===============================================");
      $display("|   MDELEG BYTE-LANE MATRIX                     |");
      $display(" ===============================================");

      ahb_read (1, MACHINE, MDELEG,     32'h0000010F, 2, 1, OK);

      // Half-word at 0x40: lanes 0 and 1.
      ahb_write(1, MACHINE, MDELEG,     32'h00000000, 1,    OK);
      ahb_read (1, MACHINE, MDELEG,     32'h00000000, 2, 1, OK);
      ahb_write(1, MACHINE, MDELEG,     32'h0000FFFF, 1,    OK);   // reserved bits dropped
      ahb_read (1, MACHINE, MDELEG,     32'h0000010F, 2, 1, OK);
      ahb_write(1, MACHINE, MDELEG,     32'h00000109, 1,    OK);   // WR=01, RD=10
      ahb_read (1, MACHINE, MDELEG,     32'h0000010D, 2, 1, OK);
      ahb_write(1, MACHINE, MDELEG,     32'h00000006, 1,    OK);   // WR=10, RD=01, RESP=0
      ahb_read (1, MACHINE, MDELEG,     32'h00000007, 2, 1, OK);

      // Byte at 0x41: RESP only (lane 0 carries 0, WR/RD non-zero must survive).
      ahb_write(1, MACHINE, MDELEG + 1, 32'h00000001, 0,    OK);
      ahb_read (1, MACHINE, MDELEG,     32'h00000107, 2, 1, OK);
      ahb_write(1, MACHINE, MDELEG + 1, 32'h000000FE, 0,    OK);   // RESP=0, reserved [15:9] set
      ahb_read (1, MACHINE, MDELEG,     32'h00000007, 2, 1, OK);
      ahb_write(1, MACHINE, MDELEG + 1, 32'h000000FF, 0,    OK);
      ahb_read (1, MACHINE, MDELEG,     32'h00000107, 2, 1, OK);

      // Byte at 0x40: WR/RD only (lane 1 carries 0, RESP=1 must survive).
      ahb_write(1, MACHINE, MDELEG,     32'h00000005, 0,    OK);
      ahb_read (1, MACHINE, MDELEG,     32'h00000105, 2, 1, OK);
      ahb_write(1, MACHINE, MDELEG,     32'h000000F6, 0,    OK);   // WR=10, RD=01, [7:4] set
      ahb_read (1, MACHINE, MDELEG,     32'h00000107, 2, 1, OK);
      ahb_write(1, MACHINE, MDELEG,     32'h00000009, 0,    OK);   // WR=01, RD=10
      ahb_read (1, MACHINE, MDELEG,     32'h0000010D, 2, 1, OK);
      ahb_write(1, MACHINE, MDELEG,     32'h0000000A, 0,    OK);   // both 10
      ahb_read (1, MACHINE, MDELEG,     32'h0000010F, 2, 1, OK);
      ahb_write(1, MACHINE, MDELEG,     32'h00000000, 0,    OK);
      ahb_read (1, MACHINE, MDELEG,     32'h00000100, 2, 1, OK);
      ahb_write(1, MACHINE, MDELEG,     32'h00000005, 0,    OK);
      ahb_read (1, MACHINE, MDELEG,     32'h00000105, 2, 1, OK);

      // Lanes 2 and 3: reserved only, nothing changes (lanes 0/1 carry 0).
      ahb_write(1, MACHINE, MDELEG + 2, 32'h000000FF, 0,    OK);
      ahb_read (1, MACHINE, MDELEG,     32'h00000105, 2, 1, OK);
      ahb_write(1, MACHINE, MDELEG + 3, 32'h000000FF, 0,    OK);
      ahb_read (1, MACHINE, MDELEG,     32'h00000105, 2, 1, OK);
      ahb_write(1, MACHINE, MDELEG + 2, 32'h0000FFFF, 1,    OK);
      ahb_read (1, MACHINE, MDELEG,     32'h00000105, 2, 1, OK);

      $display("");
      $display(" ===============================================");
      $display("|   PIPELINED MDELEG WRITE, NEXT TRANSFER       |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, REGOUT_00,  32'h11110000, 2,    OK);
      ahb_write(1, MACHINE, MDELEG,     32'h00000100, 2,    OK);

      // Write then MDELEG read.
      ahb_write(0, MACHINE, MDELEG,     32'h0000010F, 2,    OK);
      ahb_read (1, MACHINE, MDELEG,     32'h0000010F, 2, 1, OK);
      ahb_write(0, MACHINE, MDELEG,     32'h00000000, 0,    OK);
      ahb_read (1, MACHINE, MDELEG,     32'h00000100, 2, 1, OK);
      ahb_write(0, MACHINE, MDELEG,     32'h00000002, 0,    OK);   // WR=10 -> 11
      ahb_read (1, MACHINE, MDELEG,     32'h00000103, 2, 1, OK);

      // Opening the read gate admits the very next User read.
      ahb_write(1, MACHINE, MDELEG,     32'h0000010F, 2,    OK);
      ahb_write(0, MACHINE, MDELEG,     32'h00000100, 2,    OK);
      ahb_read (1, USER,    REGOUT_00,  32'h11110000, 2, 1, OK);

      // Closing it denies the very next User read.
      ahb_write(0, MACHINE, MDELEG,     32'h0000010F, 2,    OK);
      ahb_read (1, USER,    REGOUT_00,  32'h00000000, 2, 1, ERROR);

      // Closing the write gate denies the very next User write; reads stay open.
      ahb_write(1, MACHINE, MDELEG,     32'h00000100, 2,    OK);
      ahb_write(0, MACHINE, MDELEG,     32'h00000103, 2,    OK);
      ahb_write(1, USER,    REGOUT_00,  32'hBAD0BAD0, 2,    ERROR);
      check_reg_value(0, 32'h11110000);
      ahb_read (1, USER,    REGOUT_00,  32'h11110000, 2, 1, OK);

      // Opening it admits the very next User write.
      ahb_write(0, MACHINE, MDELEG,     32'h00000100, 2,    OK);
      ahb_write(1, USER,    REGOUT_00,  32'h22220000, 2,    OK);
      check_reg_value(0, 32'h22220000);

      // Byte at 0x40 closes the gates, byte at 0x41 clears RESP: the next User
      // read is denied silently; setting RESP again, the next one gets ERROR.
      ahb_write(0, MACHINE, MDELEG,     32'h0000000F, 0,    OK);
      ahb_write(0, MACHINE, MDELEG + 1, 32'h00000000, 0,    OK);
      ahb_read (1, USER,    REGOUT_00,  32'h00000000, 2, 1, OK);
      ahb_write(0, MACHINE, MDELEG + 1, 32'h00000001, 0,    OK);
      ahb_read (1, USER,    REGOUT_00,  32'h00000000, 2, 1, ERROR);

      // Supervisor gates: the next Supervisor write is admitted, then denied.
      ahb_write(0, MACHINE, MDELEG,     32'h00000105, 1,    OK);
      ahb_write(1, SUPERVISOR, REGOUT_00, 32'h33330000, 2,  OK);
      check_reg_value(0, 32'h33330000);
      ahb_write(0, MACHINE, MDELEG,     32'h0000010F, 2,    OK);
      ahb_write(1, SUPERVISOR, REGOUT_00, 32'hBAD0BAD0, 2,  ERROR);
      check_reg_value(0, 32'h33330000);

      // Reset value restored.
      ahb_write(1, MACHINE, MDELEG,     32'h0000010F, 2,    OK);
      ahb_read (1, MACHINE, MDELEG,     32'h0000010F, 2, 1, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
