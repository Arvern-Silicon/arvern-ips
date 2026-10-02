//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    burst_busy_seq
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : burst_busy_seq.v
// Module Description : SEQ and BUSY beats. A SEQ beat is a transfer like NONSEQ; a
//                      BUSY beat is not a transfer: it gets a zero-wait OKAY and
//                      writes nothing, even with a write address and data on the
//                      bus. The beats are driven back to back, pipelined.
//----------------------------------------------------------------------------

localparam REGOUT_00 = 32'h00400000;
localparam REGOUT_01 = 32'h00400004;
localparam REGOUT_02 = 32'h00400008;
localparam REGOUT_03 = 32'h0040000C;

task chk;
   input        cond;
   input [8*72-1:0] msg;
   begin
      if (cond !== 1'b1) begin
         $display("ERROR: %0s %t ns", msg, $time);
         error = error + 1;
      end
   end
endtask

// Bus back to idle, sampled on the next edge.
task bus_idle;
   begin
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hwrite = 1'b0;
      hsize  = 3'b000;
      set_mode(USER);
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk); #1;

      ahb_write(1, MACHINE, REGOUT_03, 32'h33333333, 2, OK);
      @(posedge free_clk); #1;

      set_mode(MACHINE); hwrite = 1'b1; hsize = 3'b010;
      haddr = REGOUT_00; htrans = 2'b10;                 // NONSEQ
      @(posedge free_clk); #1;
      hwdata = 32'hA0A0A0A0;
      haddr = REGOUT_01; htrans = 2'b11;                 // SEQ
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b0, "NONSEQ beat data phase not zero-wait OKAY");
      hwdata = 32'hA1A1A1A1;
      haddr = REGOUT_03; htrans = 2'b01;                 // BUSY, write address on the bus
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b0, "SEQ beat data phase not zero-wait OKAY");
      hwdata = 32'hDEADBEEF;                             // junk during the BUSY slot
      haddr = REGOUT_02; htrans = 2'b11;                 // SEQ
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b0, "BUSY beat not a zero-wait OKAY");
      hwdata = 32'hA2A2A2A2;
      bus_idle;
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b0, "last SEQ beat data phase not zero-wait OKAY");
      repeat(2) @(posedge free_clk); #1;

      chk(periph0_reg_00_out === 32'hA0A0A0A0, "NONSEQ beat not written");
      chk(periph0_reg_01_out === 32'hA1A1A1A1, "SEQ beat not written");
      chk(periph0_reg_02_out === 32'hA2A2A2A2, "SEQ beat after BUSY not written");
      chk(periph0_reg_03_out === 32'h33333333, "BUSY beat wrote its address");

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
