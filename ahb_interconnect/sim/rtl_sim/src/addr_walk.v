//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    addr_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : addr_walk.v
// Module Description : Walking-ones / walking-zeros addresses and write data through
//                      every manager port.
//
//   The bench memory map (0x0040_0000..0x0040_3080) never moves the upper address
//   bits, so the fabric's address path (manager caches, grant muxes, the address
//   replicated to every subordinate port) is otherwise only ever exercised on a
//   handful of bits. Every address here is unmapped, so each access must be
//   answered by the default subordinate with exactly one two-cycle ERROR
//   (ahb_interconnect.md: an address no decoder claims is answered ERROR; IHI0033C
//   3.2: "the Subordinate ... must use a two-cycle response").
//
//   Walking ones over bits 2..31 (bit 22 alone is the ROM base, so bit 24 is added
//   there), walking zeros over bits 2..31, a read and a write each, from every
//   manager in turn. Write data walks bits b and b-2 (ones, then zeros), so every
//   data bit rises and falls.
//----------------------------------------------------------------------------

integer aw_b;
integer aw_m;
integer aw_err0, aw_err1, aw_err2;
integer aw_before;
integer aw_done;
reg [31:0] aw_addr;
reg [31:0] aw_data;

// One count per ERROR response (its second cycle: hready = 1 with hresp = 1), on the
// bench's view of each manager.
initial begin aw_err0 = 0; aw_err1 = 0; aw_err2 = 0; end
always @(posedge free_clk) begin
   if (m0_hready === 1'b1 && m0_hresp === 1'b1) aw_err0 = aw_err0 + 1;
   if (m1_hready === 1'b1 && m1_hresp === 1'b1) aw_err1 = aw_err1 + 1;
   if (m2_hready === 1'b1 && m2_hresp === 1'b1) aw_err2 = aw_err2 + 1;
end

function integer aw_errs;
   input integer m;
   aw_errs = (m == 0) ? aw_err0 : (m == 1) ? aw_err1 : aw_err2;
endfunction

task aw_access;
   input integer m;
   input [31:0] addr;
   input        wr;
   input [31:0] data;
   begin
      aw_before = aw_errs(m);
      if (wr) ahb_write(m, 1, addr, data, 2);
      else    ahb_read (m, 1, addr, 32'h0, 2, 0);
      repeat (2) @(posedge free_clk);
      if (aw_errs(m) != aw_before + 1) begin
         $display("ERROR: M%0d %s 0x%h -- %0d ERROR response(s), expected exactly 1 %t",
                  m, wr ? "write" : "read", addr, aw_errs(m) - aw_before, $time);
         error = error + 1;
      end
      aw_done = aw_done + 1;
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(10) @(posedge free_clk);
      aw_done = 0;

      $display(" =====================================================");
      $display("|  WALKING ADDRESSES THROUGH EVERY MANAGER             |");
      $display(" =====================================================");

      for (aw_m = 0; aw_m < 3; aw_m = aw_m + 1) begin
         for (aw_b = 2; aw_b < 32; aw_b = aw_b + 1) begin
            aw_addr = 32'h1 << aw_b;
            if ((aw_addr >= 32'h0040_0000) && (aw_addr < 32'h0040_4000))
               aw_addr = aw_addr | 32'h0100_0000;            // keep it unmapped
            aw_data = (32'h1 << aw_b) | (32'h1 << (aw_b - 2));
            aw_access(aw_m, aw_addr, 1'b0, 32'h0);
            aw_access(aw_m, aw_addr, 1'b1, aw_data);
            aw_addr = ~(32'h1 << aw_b) & 32'hFFFF_FFFC;
            aw_access(aw_m, aw_addr, 1'b0, 32'h0);
            aw_access(aw_m, aw_addr, 1'b1, ~aw_data);
         end
      end

      $display("INFO:  %0d unmapped accesses, each answered by exactly one ERROR %t", aw_done, $time);

      // The fabric still works afterwards.
      ahb_write(1, 1, 32'h0040_1010, 32'h1234_5678, 2);
      ahb_read (1, 1, 32'h0040_1010, 32'h1234_5678, 2, 1);

      repeat(10) @(posedge free_clk);
      stimulus_done = 1;
   end
