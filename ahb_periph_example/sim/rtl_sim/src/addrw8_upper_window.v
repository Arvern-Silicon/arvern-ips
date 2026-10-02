//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    addrw8_upper_window
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : addrw8_upper_window.v
// Module Description : The upper half of a 256-byte window (ADDRW >= 8) is
//                      unmapped. Offsets 0x80, 0xA0, 0xC0 and 0xFC sit one
//                      ADDRW=7 wrap above REGOUT_00, REGIN_08, MDELEG and an
//                      unmapped slot: an admitted access there is an OKAY no-op
//                      reading 0 and reaches none of those registers; a denied
//                      one follows RESP (ERROR, then silent drop). Skipped when
//                      ADDRW < 8.
//----------------------------------------------------------------------------

localparam REGOUT_00 = 32'h00400000;
localparam REGIN_08  = 32'h00400020;
localparam MDELEG    = 32'h00400040;
localparam UP_80     = 32'h00400080;
localparam UP_A0     = 32'h004000A0;
localparam UP_C0     = 32'h004000C0;
localparam UP_FC     = 32'h004000FC;

integer ii;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk);

      if (ADDRW < 8) begin
         tb_skip_finish("|   needs ADDRW >= 8 (upper half of the window)  |");
      end else begin

         $display("");
         $display(" ===============================================");
         $display("|   UPPER HALF OF THE WINDOW (ADDRW=%0d)          |", ADDRW);
         $display(" ===============================================");

         for (ii = 0; ii < 8; ii = ii + 1) begin
            ahb_write(1, MACHINE, REGOUT_00 + ii*4, 32'h10203040 + ii, 2, OK);
         end
         periph0_reg_08_in = 32'hCAFE0008;

         // Machine mode (admitted): OKAY, reads 0, writes stored nowhere.
         ahb_write(1, MACHINE, UP_80,     32'hFFFFFFFF, 2,    OK);
         ahb_read (1, MACHINE, UP_80,     32'h00000000, 2, 1, OK);
         ahb_write(1, MACHINE, UP_A0,     32'h12345678, 2,    OK);
         ahb_read (1, MACHINE, UP_A0,     32'h00000000, 2, 1, OK);
         ahb_write(1, MACHINE, UP_C0,     32'h00000000, 2,    OK);
         ahb_read (1, MACHINE, UP_C0,     32'h00000000, 2, 1, OK);
         ahb_write(1, MACHINE, UP_C0,     32'h00000000, 0,    OK);
         ahb_write(1, MACHINE, UP_C0 + 1, 32'h00000000, 0,    OK);
         ahb_write(1, MACHINE, UP_C0,     32'h00000000, 1,    OK);
         ahb_write(1, MACHINE, UP_FC,     32'hFFFFFFFF, 2,    OK);
         ahb_read (1, MACHINE, UP_FC,     32'h00000000, 2, 1, OK);
         ahb_write(1, MACHINE, UP_FC + 3, 32'h000000FF, 0,    OK);
         ahb_read (1, MACHINE, UP_FC + 3, 32'h00000000, 0, 1, OK);
         ahb_write(1, MACHINE, UP_FC + 2, 32'h0000FFFF, 1,    OK);
         ahb_read (1, MACHINE, UP_FC + 2, 32'h00000000, 1, 1, OK);
         ahb_read (1, MACHINE, UP_FC,     32'h00000000, 0, 1, OK);

         ahb_read (1, MACHINE, MDELEG,    32'h0000010F, 2, 1, OK);
         ahb_read (1, MACHINE, REGOUT_00, 32'h10203040, 2, 1, OK);
         ahb_read (1, MACHINE, REGIN_08,  32'hCAFE0008, 2, 1, OK);
         for (ii = 0; ii < 8; ii = ii + 1) begin
            check_reg_value(ii, 32'h10203040 + ii);
         end

         // User mode, reset gates with RESP=1: ERROR, as anywhere in the window.
         ahb_read (1, USER,    UP_FC,     32'h00000000, 2, 1, ERROR);
         ahb_write(1, USER,    UP_FC,     32'h12345678, 2,    ERROR);

         // RESP=0, gates still Machine only: denied, dropped silently.
         ahb_write(1, MACHINE, MDELEG,    32'h0000000F, 2,    OK);
         ahb_read (1, USER,    UP_FC,     32'h00000000, 2, 1, OK);
         ahb_write(1, USER,    UP_FC,     32'h12345678, 2,    OK);
         ahb_read (1, USER,    UP_C0,     32'h00000000, 2, 1, OK);

         // Gates open to User: admitted, still an OKAY no-op reading 0.
         ahb_write(1, MACHINE, MDELEG,    32'h00000000, 2,    OK);
         ahb_read (1, USER,    UP_FC,     32'h00000000, 2, 1, OK);
         ahb_write(1, USER,    UP_FC,     32'h12345678, 2,    OK);
         ahb_write(1, USER,    UP_80,     32'hFFFFFFFF, 2,    OK);
         ahb_read (1, USER,    UP_A0,     32'h00000000, 2, 1, OK);

         ahb_write(1, MACHINE, MDELEG,    32'h0000010F, 2,    OK);
         ahb_read (1, MACHINE, MDELEG,    32'h0000010F, 2, 1, OK);
         for (ii = 0; ii < 8; ii = ii + 1) begin
            check_reg_value(ii, 32'h10203040 + ii);
         end
         periph0_reg_08_in = 32'h00000000;

         repeat(21) @(posedge free_clk);
         $display("");
         stimulus_done = 1;
      end
   end
