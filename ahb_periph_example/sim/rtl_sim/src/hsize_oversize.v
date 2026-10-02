//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    hsize_oversize
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : hsize_oversize.v
// Module Description : Transfer sizes above a word. Only hsize[1:0] is decoded:
//                      3'b011 selects no byte lane (a write stores nothing, a read
//                      returns the word), 3'b100..3'b110 behave as byte, half-word
//                      and word. Every response is OKAY with no wait state.
//----------------------------------------------------------------------------

localparam REGOUT_00 = 32'h00400000;

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

// One single-beat Machine-mode transfer with a raw 3-bit hsize.
task xfer;
   input        write;
   input [31:0] addr;
   input  [2:0] size;
   input [31:0] wdata;       // already placed on its byte lanes
   input [31:0] exp_rdata;   // checked on reads, full word
   begin
      haddr  = addr;
      htrans = 2'b10;
      hwrite = write;
      hsize  = size;
      set_mode(MACHINE);
      @(posedge free_clk); #1;
      bus_idle;
      hwdata = wdata;
      chk(hreadyout === 1'b1 && hresp === 1'b0, "oversized transfer: data phase not a zero-wait OKAY");
      if (!write) chk(hrdata === exp_rdata, "oversized transfer: read data mismatch");
      @(posedge free_clk); #1;
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk); #1;

      ahb_write(1, MACHINE, REGOUT_00, 32'h11223344, 2, OK);
      @(posedge free_clk); #1;

      xfer(1, REGOUT_00,         3'b011, 32'hFFFFFFFF, 32'h0);
      chk(periph0_reg_00_out === 32'h11223344, "hsize=3'b011 write changed the register");
      xfer(0, REGOUT_00,         3'b011, 32'h0,        32'h11223344);

      xfer(1, REGOUT_00 + 32'h1, 3'b100, 32'h0000AA00, 32'h0);
      chk(periph0_reg_00_out === 32'h1122AA44, "hsize=3'b100 did not write as a byte");
      xfer(1, REGOUT_00 + 32'h2, 3'b101, 32'hBBCC0000, 32'h0);
      chk(periph0_reg_00_out === 32'hBBCCAA44, "hsize=3'b101 did not write as a half-word");
      xfer(1, REGOUT_00,         3'b110, 32'h55667788, 32'h0);
      chk(periph0_reg_00_out === 32'h55667788, "hsize=3'b110 did not write as a word");
      xfer(0, REGOUT_00,         3'b110, 32'h0,        32'h55667788);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
