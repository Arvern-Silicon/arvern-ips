//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    size_align_contest
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : size_align_contest.v
// Module Description : Byte / halfword / word transfers at every byte offset
//                      while the other managers contend for the same
//                      subordinate, so address phases are cached and
//                      replayed after a delayed grant. All variants.
//
// Each manager owns a window of SRAM words and is its only writer; a shadow
// copy is updated in issue order, so every read (checked inline by the bench
// tasks, lane by lane) and the final full-word read-back have an exact
// expected value. The same managers read the ROM at every size and offset in
// parallel, contending on the ROM as well.
//
// Size / offset combinations
//   generic, hiperf : all twelve (byte 0..3, halfword 0..3, word 0..3). The
//                     misaligned ones are defined by the subordinate docs.
//   fused           : byte 0..3, halfword 0/2, word 0. The fused SRAM
//                     controller's behaviour on a misaligned halfword/word is
//                     not stated in ahb_interconnect.md, so it is not tested.
//                     M0 (Port A) is read-only: it streams reads of its own
//                     preloaded window at every size/offset while M1/M2
//                     write theirs through Port B, so Port-B writes lose
//                     contests to Port-A reads in their data phase and are
//                     parked in the write buffer. A write/read of the same
//                     word follows every write (read of the buffered word).
//                     The test requires at least one buffered-write cycle:
//                     a cycle in which the macro is written although no
//                     Port-B write data phase ends in it.
//
// Basis (quoted)
//  IHI0033C Table 6-1 (Active byte lanes, 32-bit little-endian): "Byte 0 ...
//    DATA[7:0]", "Byte 1 ... DATA[15:8]", "Byte 2 ... DATA[23:16]", "Byte 3
//    ... DATA[31:24]", "Halfword 0 ... DATA[15:0]", "Halfword 2 ...
//    DATA[31:16]".
//  IHI0033C 3.5.2: "For the transfers, which are narrower than the data bus,
//    HSIZE and HADDR determine which byte lanes are active."
//  ahb_interconnect.md, Integration requirements: "Misaligned accesses are
//    not checked; the fabric expects managers and subordinates to handle
//    them".
//  ahb_sram_controller.md: "The byte lanes selected by hsize_i[1:0] and
//    haddr_i[1:0] are written at the edge that ends the data phase; an
//    unaligned half-word or word uses the lanes of the aligned half-word or
//    word containing it." / "The aligned 32-bit word containing haddr_i is on
//    hrdata_o in the next cycle ... a narrower manager takes its byte lanes."
//  ahb_rom_controller.md: "hsize_i and haddr_i[1:0] are ignored: a narrower
//    manager takes its byte lanes, a word read at an unaligned address returns
//    the aligned word"
//  ahb_interconnect.md, Fused fabric: "Port B ... supports reads and
//    byte-enabled writes on the SRAM controller"; "A Port-B write whose data
//    phase collides with a read on either port ... is held in a one-word
//    buffer and written to the macro in the very next cycle, during which
//    neither port is granted."; "A Port-B read of the buffered word in the
//    collision cycle is served from the buffer"; "the fused ROM controller
//    ignores hsize altogether on both ports and returns the full word."
//  ahb_interconnect.md, Building blocks: ahb_manager_if "caches it when the
//    bus is busy, asks the arbiter for the bus, replays the cached address
//    phase when granted".
//----------------------------------------------------------------------------

localparam [31:0] SA_ROM  = 32'h00400000;
localparam [31:0] SA_SRAM = 32'h00401000;

integer    sa_i;
integer    sa_p0;
integer    sa_k0;
integer    sa_p1;
integer    sa_k1;
integer    sa_p2;
integer    sa_k2;
integer    sa_errs;
reg [31:0] sa_shadow [0:511];

// Word windows: M0 words 0..11, M1 words 64..75, M2 words 128..139
function integer sa_base;
   input integer m;
   begin
      sa_base = m * 64;
   end
endfunction

function [31:0] sa_init;
   input integer w;
   begin
      sa_init = {8'h11, 8'h22, 8'h33, 2'b00, w[5:0]};
   end
endfunction

function [31:0] sa_wdata;
   input integer m;
   input integer p;
   input integer k;
   begin
      sa_wdata = ((32'h40 + (m*16) + p) << 24) |
                 ((32'hA0 + k)          << 16) |
                 ((32'hC0 + k + p)      <<  8) |
                  (32'hE0 + (p*4) + m);
   end
endfunction

// Size/offset combination c (0..11): size = c/4, offset = c%4. On fused a
// misaligned halfword/word is moved to the aligned offset containing it.
function [1:0] sa_size;
   input integer c;
   begin
      sa_size = c / 4;
   end
endfunction

function [1:0] sa_off;
   input integer c;
   reg     [1:0] sz;
   reg     [1:0] ofs;
   begin
      sz = c / 4;
      ofs = c % 4;
`ifdef FUSED
      if (sz == 2'd1) ofs = ofs & 2'b10;
      if (sz == 2'd2) ofs = 2'b00;
`endif
      sa_off = ofs;
   end
endfunction

// New word after a write of `data` (placed by the bench tasks on its lanes)
function [31:0] sa_merge;
   input [31:0] old;
   input [31:0] data;
   input  [1:0] size;
   input  [1:0] off;
   reg   [31:0] r;
   begin
      r = old;
      if (size == 2'd0)
         case (off)
            2'd0: r[7:0]   = data[7:0];
            2'd1: r[15:8]  = data[7:0];
            2'd2: r[23:16] = data[7:0];
            2'd3: r[31:24] = data[7:0];
         endcase
      else if (size == 2'd1)
         begin
            if (off[1]) r[31:16] = data[15:0];
            else        r[15:0]  = data[15:0];
         end
      else
         r = data;
      sa_merge = r;
   end
endfunction

// Expected-data argument of the bench read task for a word `w`
function [31:0] sa_rdarg;
   input [31:0] w;
   input  [1:0] size;
   input  [1:0] off;
   begin
      if (size == 2'd0)      sa_rdarg = w >> (8 * off);
      else if (size == 2'd1) sa_rdarg = off[1] ? (w >> 16) : w;
      else                   sa_rdarg = w;
   end
endfunction

task automatic sa_write;
   input integer m;
   input integer w;          // SRAM word index
   input integer c;          // size/offset combination
   input  [31:0] d;
   reg     [1:0] sz;
   reg     [1:0] ofs;
   begin
      sz = sa_size(c);
      ofs = sa_off(c);
      sa_shadow[w] = sa_merge(sa_shadow[w], d, sz, ofs);
      ahb_write(m, 0, SA_SRAM + 4*w + ofs, d, sz);
   end
endtask

task automatic sa_read;
   input integer m;
   input integer w;
   input integer c;
   reg     [1:0] sz;
   reg     [1:0] ofs;
   begin
      sz = sa_size(c);
      ofs = sa_off(c);
      ahb_read(m, 0, SA_SRAM + 4*w + ofs, sa_rdarg(sa_shadow[w], sz, ofs), sz, 1);
   end
endtask

task automatic sa_rom_read;
   input integer m;
   input integer w;
   input integer c;
   reg     [1:0] sz;
   reg     [1:0] ofs;
   begin
      sz = sa_size(c);
      ofs = sa_off(c);
      ahb_read(m, 0, SA_ROM + 4*w + ofs, sa_rdarg(rom_inst0.mem[w], sz, ofs), sz, 1);
   end
endtask

// One manager's pass p over its window. Writers: write, read back at the
// same size/offset, read the full word, read at another size/offset, read
// the ROM at yet another size/offset -- all pipelined.
task automatic sa_pass;
   input integer m;
   input integer p;
   integer       k;
   integer       c;
   integer       w;
   begin
      for (k = 0; k < 12; k = k + 1)
         begin
            c = (k + 5*p + 3*m) % 12;
            w = sa_base(m) + k;
`ifdef FUSED
            if (m == 0)
               begin
                  sa_read    (0, w, c);
                  sa_read    (0, w, (c + 7) % 12);
                  sa_read    (0, w, 8);
                  sa_rom_read(0, 16*p + k, (c + 3) % 12);
               end
            else
`endif
               begin
                  sa_write   (m, w, c, sa_wdata(m, p, k));
                  sa_read    (m, w, c);
                  sa_read    (m, w, 8);
                  sa_read    (m, w, (c + 7) % 12);
                  sa_rom_read(m, 16*p + k, (c + 3) % 12);
               end
         end
   end
endtask


//----------------------------------------------------------------------------
// Response recorder (all transfers here must be OKAY) and, on fused, the
// buffered-write detector.
//----------------------------------------------------------------------------
reg        rc_out  [0:2];
reg        rc_wr   [0:2];
reg        rc_sram [0:2];
integer    rc_n    [0:2];
integer    rc_errs [0:2];
integer    rc_k;
reg        rc_bwend;          // a Port-B (M1/M2) SRAM write data phase ended at this edge
integer    sa_bufw;           // buffered-write cycles seen (fused)

initial
   begin
      for (rc_k = 0; rc_k < 3; rc_k = rc_k + 1)
         begin
            rc_out[rc_k]  = 1'b0;
            rc_wr[rc_k]   = 1'b0;
            rc_sram[rc_k] = 1'b0;
            rc_n[rc_k]    = 0;
            rc_errs[rc_k] = 0;
         end
      sa_bufw = 0;
   end

task rc_sample;
   input integer m;
   input         aph;
   input         wr;
   input  [31:0] a;
   input         rdy;
   input         rsp;
   begin
      if (rc_out[m] & rdy)
         begin
            if (rsp) rc_errs[m] = rc_errs[m] + 1;
            if ((m != 0) & rc_wr[m] & rc_sram[m]) rc_bwend = 1'b1;
            rc_n[m]   = rc_n[m] + 1;
            rc_out[m] = 1'b0;
         end
      if (aph & rdy)
         begin
            rc_out[m]  = 1'b1;
            rc_wr[m]   = wr;
            rc_sram[m] = (a >= SA_SRAM) && (a < SA_SRAM + 32'h800);
         end
   end
endtask

always @(posedge free_clk)
   if (!hresetn)
      begin
         for (rc_k = 0; rc_k < 3; rc_k = rc_k + 1)
            rc_out[rc_k] = 1'b0;
      end
   else if (tb_rst_done)
      begin
         rc_bwend = 1'b0;
         rc_sample(0, m0_htrans_d[1], m0_hwrite_d, m0_haddr_d, m0_hready, m0_hresp);
         rc_sample(1, m1_htrans_d[1], m1_hwrite_d, m1_haddr_d, m1_hready, m1_hresp);
         rc_sample(2, m2_htrans_d[1], m2_hwrite_d, m2_haddr_d, m2_hready, m2_hresp);
`ifdef FUSED
         // Macro write command in the cycle ending here with no Port-B write
         // data phase ending here: the parked write of a collision.
         if ((sram0_cen === 1'b0) && (sram0_wen !== 4'hF) && !rc_bwend)
            sa_bufw = sa_bufw + 1;
`endif
      end


//----------------------------------------------------------------------------
// Delayed-grant evidence
//----------------------------------------------------------------------------
wire sa_m0_pend;
wire sa_m1_pend;
wire sa_m2_pend;
`ifdef FUSED
assign sa_m0_pend = 1'b0;
assign sa_m1_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
assign sa_m2_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
`elsif HIPERF
assign sa_m0_pend = 1'b0;
assign sa_m1_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
assign sa_m2_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
`else
assign sa_m0_pend = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
assign sa_m1_pend = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
assign sa_m2_pend = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[2].ahb_manager_if_inst.m_aph_pending;
`endif

integer sa_pc0;
integer sa_pc1;
integer sa_pc2;
initial
   begin
      sa_pc0 = 0;
      sa_pc1 = 0;
      sa_pc2 = 0;
   end

always @(posedge free_clk)
   if (hresetn && tb_rst_done)
      begin
         if (sa_m0_pend === 1'b1) sa_pc0 = sa_pc0 + 1;
         if (sa_m1_pend === 1'b1) sa_pc1 = sa_pc1 + 1;
         if (sa_m2_pend === 1'b1) sa_pc2 = sa_pc2 + 1;
      end


//----------------------------------------------------------------------------
// Stimulus
//----------------------------------------------------------------------------
initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(10) @(posedge free_clk);

      $display("");
      $display(" =====================================================");
      $display("|  SIZE / OFFSET UNDER CONTENTION (M0 / M1 / M2)       |");
      $display(" =====================================================");

      for (tb_idx = 0; tb_idx < MEM_SIZE/4; tb_idx = tb_idx + 1)
         rom_inst0.mem[tb_idx]  = {8'h70 + tb_idx[5:0], 8'h91 ^ tb_idx[7:0], 8'hB2 + tb_idx[7:0], 8'hD3 ^ tb_idx[7:0]};
      for (tb_idx = 0; tb_idx < MEM_SIZE/4; tb_idx = tb_idx + 1)
         begin
            sram_inst0.mem[tb_idx] = sa_init(tb_idx);
            sa_shadow[tb_idx]      = sa_init(tb_idx);
         end

      @(negedge free_clk);
      force   ahb_periph_example_inst0.hresetn_i = 1'b0;
      force   ahb_periph_example_inst1.hresetn_i = 1'b0;
      @(negedge free_clk);
      release ahb_periph_example_inst0.hresetn_i;
      release ahb_periph_example_inst1.hresetn_i;
      repeat(10) @(posedge free_clk);

      sa_pc0 = 0; sa_pc1 = 0; sa_pc2 = 0;
      sa_bufw = 0;

      fork
         begin
            for (sa_p0 = 0; sa_p0 < 3; sa_p0 = sa_p0 + 1) sa_pass(0, sa_p0);
         end
         begin
            for (sa_p1 = 0; sa_p1 < 3; sa_p1 = sa_p1 + 1) sa_pass(1, sa_p1);
         end
         begin
            for (sa_p2 = 0; sa_p2 < 3; sa_p2 = sa_p2 + 1) sa_pass(2, sa_p2);
         end
      join
      repeat(30) @(posedge free_clk);

      //---------------------------------------------------------------
      // Full-word read-back of every window, then the macro contents
      //---------------------------------------------------------------
      $display("");
      $display("Full-word read-back");
      fork
         begin
            for (sa_k0 = 0; sa_k0 < 12; sa_k0 = sa_k0 + 1)
               ahb_read(0, 0, SA_SRAM + 4*(sa_base(0) + sa_k0), sa_shadow[sa_base(0) + sa_k0], 2, 1);
         end
         begin
            for (sa_k1 = 0; sa_k1 < 12; sa_k1 = sa_k1 + 1)
               ahb_read(1, 0, SA_SRAM + 4*(sa_base(1) + sa_k1), sa_shadow[sa_base(1) + sa_k1], 2, 1);
         end
         begin
            for (sa_k2 = 0; sa_k2 < 12; sa_k2 = sa_k2 + 1)
               ahb_read(2, 0, SA_SRAM + 4*(sa_base(2) + sa_k2), sa_shadow[sa_base(2) + sa_k2], 2, 1);
         end
      join
      repeat(20) @(posedge free_clk);

      for (sa_i = 0; sa_i < 12; sa_i = sa_i + 1)
         begin
            check_mem_value(sa_base(0) + sa_i, sa_shadow[sa_base(0) + sa_i]);
            check_mem_value(sa_base(1) + sa_i, sa_shadow[sa_base(1) + sa_i]);
            check_mem_value(sa_base(2) + sa_i, sa_shadow[sa_base(2) + sa_i]);
         end
      // Words next to the windows were never addressed
      check_mem_value(sa_base(0) + 12, sa_init(sa_base(0) + 12));
      check_mem_value(sa_base(1) + 12, sa_init(sa_base(1) + 12));
      check_mem_value(sa_base(2) + 12, sa_init(sa_base(2) + 12));
      check_mem_value(sa_base(1) - 1,  sa_init(sa_base(1) - 1));
      check_mem_value(sa_base(2) - 1,  sa_init(sa_base(2) - 1));

      //---------------------------------------------------------------
      // Scenario evidence
      //---------------------------------------------------------------
      sa_errs = rc_errs[0] + rc_errs[1] + rc_errs[2];
      if (sa_errs != 0)
         begin
            $display("ERROR: %0d ERROR responses on mapped ROM/SRAM reads and SRAM writes", sa_errs);
            error = error + 1;
         end
      $display("INFO:  cached-APH cycles: M0 %0d  M1 %0d  M2 %0d", sa_pc0, sa_pc1, sa_pc2);
      if ((sa_pc1 == 0) || (sa_pc2 == 0))
         begin
            $display("ERROR: no delayed grant observed on M1/M2 -- contention scenario not reached");
            error = error + 1;
         end
`ifdef GENERIC
      if (sa_pc0 == 0)
         begin
            $display("ERROR: no delayed grant observed on M0 -- contention scenario not reached");
            error = error + 1;
         end
`endif
`ifdef FUSED
      $display("INFO:  buffered Port-B write cycles: %0d", sa_bufw);
      if (sa_bufw == 0)
         begin
            $display("ERROR: no Port-B write was parked by a Port-A read -- write-buffer scenario not reached");
            error = error + 1;
         end
`endif

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
