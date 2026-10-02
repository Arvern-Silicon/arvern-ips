//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    rw_data_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : rw_data_walk.v
// Module Description : Every data bit of every REGOUT_* register rises and falls,
//                      on register_XX_o and on hrdata_o. All-ones then all-zeros
//                      words are read back as word, both half-words and all four
//                      bytes; a walking one is written with byte writes (the
//                      holding lane carries the bit, the other lanes 0) and a
//                      walking zero with word writes, each read back as a word
//                      and checked on the output port.
//----------------------------------------------------------------------------

localparam REGOUT_00 = 32'h00400000;

integer    ii;
integer    bb;
integer    ll;
reg [31:0] reg_addr;
reg [31:0] pattern;

// Word write of a value, read back as word, half-words and bytes.
task write_readback_all;
   input integer    reg_nr;
   input     [31:0] value;
   begin
      ahb_write(1, MACHINE, REGOUT_00 + reg_nr*4,     value,         2,    OK);
      check_reg_value(reg_nr, value);
      ahb_read (0, MACHINE, REGOUT_00 + reg_nr*4,     value,         2, 1, OK);
      ahb_read (0, MACHINE, REGOUT_00 + reg_nr*4,     value[15:0],   1, 1, OK);
      ahb_read (0, MACHINE, REGOUT_00 + reg_nr*4 + 2, value[31:16],  1, 1, OK);
      ahb_read (0, MACHINE, REGOUT_00 + reg_nr*4,     value[7:0],    0, 1, OK);
      ahb_read (0, MACHINE, REGOUT_00 + reg_nr*4 + 1, value[15:8],   0, 1, OK);
      ahb_read (0, MACHINE, REGOUT_00 + reg_nr*4 + 2, value[23:16],  0, 1, OK);
      ahb_read (1, MACHINE, REGOUT_00 + reg_nr*4 + 3, value[31:24],  0, 1, OK);
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk);

      $display("");
      $display(" ===============================================");
      $display("|   REGOUT_* DATA WALK (ones / zeros / walks)   |");
      $display(" ===============================================");

      for (ii = 0; ii < 8; ii = ii + 1) begin
         reg_addr = REGOUT_00 + ii*4;

         write_readback_all(ii, 32'hFFFFFFFF);
         write_readback_all(ii, 32'h00000000);

         // Walking one, byte writes on all four lanes.
         for (bb = 0; bb < 32; bb = bb + 1) begin
            pattern = 32'h00000001 << bb;
            for (ll = 0; ll < 4; ll = ll + 1) begin
               ahb_write(0, MACHINE, reg_addr + ll, pattern >> (ll*8), 0, OK);
            end
            ahb_read (1, MACHINE, reg_addr, pattern, 2, 1, OK);
            check_reg_value(ii, pattern);
         end

         // Walking zero, word writes.
         for (bb = 0; bb < 32; bb = bb + 1) begin
            pattern = ~(32'h00000001 << bb);
            ahb_write(0, MACHINE, reg_addr, pattern, 2, OK);
            ahb_read (1, MACHINE, reg_addr, pattern, 2, 1, OK);
            check_reg_value(ii, pattern);
         end
      end

      // No register was disturbed by the walks on the others.
      for (ii = 0; ii < 8; ii = ii + 1) begin
         check_reg_value(ii, 32'h7FFFFFFF);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
