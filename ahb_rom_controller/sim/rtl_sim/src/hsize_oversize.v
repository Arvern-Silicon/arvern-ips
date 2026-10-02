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
// Module Description : Reads with an oversized hsize_i. ahb_rom_controller.md:
//                      "Read (NONSEQ or SEQ, any hsize_i) -- One ROM read. The
//                      aligned 32-bit word containing haddr_i is on hrdata_o in the
//                      next cycle with a zero-wait OKAY. ... an oversized hsize_i is
//                      not checked." Each read with hsize 3'b011..3'b111 returns its
//                      word with a zero-wait OKAY, interleaved with word reads so
//                      hsize_i[2] rises and falls.
//----------------------------------------------------------------------------

localparam OS_BASE = 32'h00400000;

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

// One read: address phase at edge+1, data phase checked 2 ns after the next edge
// (past the bench's 1 ns input delay).
task os_read;
   input [31:0] addr;
   input  [2:0] size;
   input [31:0] expv;
   begin
      haddr = addr; htrans = 2'b10; hwrite = 1'b0; hsize = size;
      @(posedge free_clk); #1;
      haddr = 32'h00000000; htrans = 2'b00; hsize = 3'b010;
      #1;
      chk(hreadyout === 1'b1, "oversized read was not zero-wait");
      chk(hresp === 1'b0, "oversized read did not answer OKAY");
      chk(hrdata === expv, "oversized read returned the wrong word");
      @(posedge free_clk); #1;
   end
endtask

integer os_s;
integer os_w;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      for (os_w = 0; os_w < 2; os_w = os_w + 1)
         rom_inst.mem[os_w] = 32'hA5A50000 + os_w;
      repeat(5) @(posedge free_clk); #1;

      for (os_s = 3; os_s < 8; os_s = os_s + 1) begin
         os_read(OS_BASE + 4*(os_s % 2), os_s[2:0], 32'hA5A50000 + (os_s % 2));
         os_read(OS_BASE + 4*((os_s + 1) % 2), 3'b010, 32'hA5A50000 + ((os_s + 1) % 2));
      end
      $display("PASS:  oversized hsize reads returned their words with a zero-wait OKAY %t ns", $time);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
