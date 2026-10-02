//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    register_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : register_walk.v
// Module Description : Every bit of every implemented register, at any
//                      configuration. Each RW register is written 0xFFFFFFFF,
//                      0xAAAAAAAA, 0x55555555, 0x00000000, each value read back
//                      over the interface and on its ccsr_*_rw_o slice. Each RO
//                      input slice is driven 0xFFFFFFFF then 0x00000000 and read.
//                      With a RO group disabled (its 1-bit input tied low), or a
//                      RW group disabled, every address of its banks reads 0 and
//                      a write there changes nothing. Everything ends at 0.
//
// Doc sentences relied on:
//  - "The IP performs no privilege, access-type or existence check. [...]
//    The IP trusts its inputs." (no privilege level to set on the bench)
//  - "Register i of a RW group sits at bank i / 64 of the group's banks,
//    offset i mod 64, and occupies ccsr_*_rw_o[32i+31:32i]; register i of a
//    RO group sits at offset i of its bank and is read from
//    ccsr_*_ro_i[32i+31:32i]."
//  - "Read of an implemented RO register: The ccsr_*_ro_i slice on
//    ccsr_rdata_o in the same cycle, unregistered"
//  - "On a write [...] the IP captures it at the edge that ends the cycle,
//    and the ccsr_*_rw_o slice shows the new value from the next cycle."
//  - "0 disables a group: its sub-instance is not built, its port is 1 bit
//    wide (... a RO input that is unused, to be tied low), and every address
//    of its banks reads 0 and ignores writes."
//----------------------------------------------------------------------------

// Group g: 0 User, 1 Supervisor, 2 Machine.
function integer rw_count;
   input integer g;
   begin
      rw_count = (g == 0) ? NR_USR_RW : (g == 1) ? NR_SUP_RW : NR_MAC_RW;
   end
endfunction

function integer ro_count;
   input integer g;
   begin
      ro_count = (g == 0) ? NR_USR_RO : (g == 1) ? NR_SUP_RO : NR_MAC_RO;
   end
endfunction

function [11:0] rw_addr;
   input integer g;
   input integer i;
   begin
      case (g)
         0:       rw_addr = 12'h800 + i;
         1:       rw_addr = (i < 64) ? (12'h5C0 + i) : (12'h9C0 + (i - 64));
         default: rw_addr = (i < 64) ? (12'h7C0 + i) : (12'hBC0 + (i - 64));
      endcase
   end
endfunction

function [11:0] ro_addr;
   input integer g;
   input integer i;
   begin
      case (g)
         0:       ro_addr = 12'hCC0 + i;
         1:       ro_addr = 12'hDC0 + i;
         default: ro_addr = 12'hFC0 + i;
      endcase
   end
endfunction

function [31:0] rw_slice;
   input integer g;
   input integer i;
   begin
      case (g)
         0:       rw_slice = usr_rw_pad[32*i+:32];
         1:       rw_slice = sup_rw_pad[32*i+:32];
         default: rw_slice = mac_rw_pad[32*i+:32];
      endcase
   end
endfunction

function [31:0] pattern;
   input integer p;
   begin
      case (p)
         0:       pattern = 32'hFFFFFFFF;
         1:       pattern = 32'hAAAAAAAA;
         2:       pattern = 32'h55555555;
         default: pattern = 32'h00000000;
      endcase
   end
endfunction

task set_ro;
   input integer g;
   input integer i;
   input [31:0]  val;
   begin
      case (g)
         0:       usr_ro_pad[32*i+:32] = val;
         1:       sup_ro_pad[32*i+:32] = val;
         default: mac_ro_pad[32*i+:32] = val;
      endcase
   end
endtask

// Read with an error-only check.
task walk_rd;
   input [11:0] addr;
   input [31:0] expected;
   begin
      #1;
      ccsr_bank    = csr_addr_to_bank(addr);
      ccsr_reg_sel = (64'h0000000000000001 << addr[5:0]);
      ccsr_wen     = 1'b0;
      @(posedge free_clk);
      if (ccsr_rdata !== expected) begin
         $display("ERROR: read 0x%h -- 0x%h, expected 0x%h %t ns", addr, ccsr_rdata, expected, $time);
         error = error + 1;
      end
      #1;
      ccsr_bank    = 11'h000;
      ccsr_reg_sel = 64'h0000000000000000;
   end
endtask

task check_slice;
   input integer g;
   input integer i;
   input [31:0]  expected;
   begin
      if (rw_slice(g, i) !== expected) begin
         $display("ERROR: rw_o group %0d [%0d] 0x%h, expected 0x%h %t ns", g, i, rw_slice(g, i), expected, $time);
         error = error + 1;
      end
   end
endtask

// Reference values held in register 0 of every enabled group during the
// disabled-RO-input toggles.
function [31:0] ref_val;
   input integer g;
   input integer ro;
   begin
      ref_val = {8'hC3, ro[7:0], 8'h5A, g[7:0]};
   end
endfunction

task check_refs;
   integer h;
   begin
      for (h = 0; h < 3; h = h + 1) begin
         if (rw_count(h) > 0) walk_rd(rw_addr(h, 0), ref_val(h, 0));
         if (ro_count(h) > 0) walk_rd(ro_addr(h, 0), ref_val(h, 1));
      end
   end
endtask

integer gg;
integer ii;
integer pp;
integer oo;
integer hh;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk);

      // RW registers: every stored bit and every ccsr_*_rw_o bit rises and falls.
      for (gg = 0; gg < 3; gg = gg + 1)
         for (ii = 0; ii < rw_count(gg); ii = ii + 1)
            for (pp = 0; pp < 4; pp = pp + 1) begin
               csr_read_write(rw_addr(gg, ii), pattern(pp), 32'h0, 0);
               walk_rd(rw_addr(gg, ii), pattern(pp));
               check_slice(gg, ii, pattern(pp));
            end

      // RO registers: every bit of every ccsr_*_ro_i slice rises and falls.
      for (gg = 0; gg < 3; gg = gg + 1)
         for (ii = 0; ii < ro_count(gg); ii = ii + 1) begin
            set_ro(gg, ii, 32'hFFFFFFFF);
            walk_rd(ro_addr(gg, ii), 32'hFFFFFFFF);
            set_ro(gg, ii, 32'h00000000);
            walk_rd(ro_addr(gg, ii), 32'h00000000);
         end

      // Disabled RO group: its 1-bit input stays tied low (the doc's contract); every
      // address of its banks reads 0 and a write there changes no register.
      for (gg = 0; gg < 3; gg = gg + 1)
         if (ro_count(gg) == 0) begin
            for (hh = 0; hh < 3; hh = hh + 1) begin
               if (rw_count(hh) > 0) csr_read_write(rw_addr(hh, 0), ref_val(hh, 0), 32'h0, 0);
               if (ro_count(hh) > 0) set_ro(hh, 0, ref_val(hh, 1));
            end
            for (oo = 0; oo < 64; oo = oo + 1)
               walk_rd(ro_addr(gg, oo), 32'h00000000);
            csr_read_write(ro_addr(gg, 0), 32'hFFFFFFFF, 32'h0, 0);
            check_refs;
            for (hh = 0; hh < 3; hh = hh + 1) begin
               if (rw_count(hh) > 0) csr_read_write(rw_addr(hh, 0), 32'h00000000, 32'h0, 0);
               if (ro_count(hh) > 0) set_ro(hh, 0, 32'h00000000);
            end
         end

      // Disabled RW group: every address of its banks (256 user, 128 supervisor or
      // machine) reads 0 and a write there changes no register.
      for (gg = 0; gg < 3; gg = gg + 1)
         if (rw_count(gg) == 0) begin
            for (hh = 0; hh < 3; hh = hh + 1) begin
               if (rw_count(hh) > 0) csr_read_write(rw_addr(hh, 0), ref_val(hh, 0), 32'h0, 0);
               if (ro_count(hh) > 0) set_ro(hh, 0, ref_val(hh, 1));
            end
            for (ii = 0; ii < ((gg == 0) ? 256 : 128); ii = ii + 1) begin
               csr_read_write(rw_addr(gg, ii), 32'hFFFFFFFF, 32'h0, 0);
               walk_rd(rw_addr(gg, ii), 32'h00000000);
            end
            check_refs;
            for (hh = 0; hh < 3; hh = hh + 1) begin
               if (rw_count(hh) > 0) csr_read_write(rw_addr(hh, 0), 32'h00000000, 32'h0, 0);
               if (ro_count(hh) > 0) set_ro(hh, 0, 32'h00000000);
            end
         end

      if ((|usr_rw_pad) | (|sup_rw_pad) | (|mac_rw_pad) |
          (|usr_ro_pad) | (|sup_ro_pad) | (|mac_ro_pad)) begin
         $display("ERROR: registers or RO inputs not left at 0 %t ns", $time);
         error = error + 1;
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
