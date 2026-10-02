//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ro_input_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ro_input_walk.v
// Module Description : Every bit of every register_XX_i input reaches hrdata_o
//                      rising and falling: all-ones / all-zeros read as word,
//                      byte and half-word, then a walking one and a walking zero
//                      read as words. REGIN_* reads come straight from the inputs
//                      (no sampling flop), so an input that changes early in the
//                      data phase is returned with its new value in that same
//                      data phase.
//----------------------------------------------------------------------------

localparam REGIN_08 = 32'h00400020;

integer    ii;
integer    bb;
reg [31:0] reg_addr;
reg [31:0] pattern;

task chk;
   input            cond;
   input [8*72-1:0] msg;
   begin
      if (cond !== 1'b1) begin
         $display("ERROR: %0s %t ns", msg, $time);
         error = error + 1;
      end
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk);

      $display("");
      $display(" ===============================================");
      $display("|   REGIN_* INPUT WALK (ones / zeros / walks)   |");
      $display(" ===============================================");

      for (ii = 8; ii < 16; ii = ii + 1) begin
         reg_addr = REGIN_08 + (ii-8)*4;

         set_regin_value(ii, 32'hFFFFFFFF);
         ahb_read (0, MACHINE, reg_addr,     32'hFFFFFFFF, 2, 1, OK);
         ahb_read (0, MACHINE, reg_addr + 1, 32'h000000FF, 0, 1, OK);
         ahb_read (1, MACHINE, reg_addr + 2, 32'h0000FFFF, 1, 1, OK);

         set_regin_value(ii, 32'h00000000);
         ahb_read (0, MACHINE, reg_addr,     32'h00000000, 2, 1, OK);
         ahb_read (0, MACHINE, reg_addr + 1, 32'h00000000, 0, 1, OK);
         ahb_read (1, MACHINE, reg_addr + 2, 32'h00000000, 1, 1, OK);

         for (bb = 0; bb < 32; bb = bb + 1) begin
            pattern = 32'h00000001 << bb;
            set_regin_value(ii, pattern);
            ahb_read (1, MACHINE, reg_addr, pattern, 2, 1, OK);
         end

         for (bb = 0; bb < 32; bb = bb + 1) begin
            pattern = ~(32'h00000001 << bb);
            set_regin_value(ii, pattern);
            ahb_read (1, MACHINE, reg_addr, pattern, 2, 1, OK);
         end

         set_regin_value(ii, 32'h00000000);
      end

      $display("");
      $display(" ===============================================");
      $display("|   REGIN_* INPUT CHANGE IN THE DATA PHASE      |");
      $display(" ===============================================");

      // Address phase with the old value on the input; the input moves 1 ns
      // after the edge that takes the address phase, and the data phase must
      // return the new value.
      for (ii = 8; ii < 16; ii = ii + 1) begin
         reg_addr = REGIN_08 + (ii-8)*4;
         set_regin_value(ii, 32'hA5A5A5A5);
         @(posedge free_clk); #1;
         haddr = reg_addr; htrans = 2'b10; hwrite = 1'b0; hsize = 3'b010; set_mode(MACHINE);
         @(posedge free_clk);
         set_regin_value(ii, 32'h5A5A5A5A);
         haddr = 32'h00000000; htrans = 2'b00; hsize = 3'b000; set_mode(USER);
         chk(hreadyout === 1'b1 && hresp === 1'b0, "REGIN data phase not a zero-wait OKAY");
         #4;
         chk(hrdata === 32'h5A5A5A5A, "REGIN data phase did not return the new input value (early)");
         @(negedge free_clk); #20;
         chk(hrdata === 32'h5A5A5A5A, "REGIN data phase did not return the new input value (late)");
         @(posedge free_clk); #1;
         set_regin_value(ii, 32'h00000000);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
