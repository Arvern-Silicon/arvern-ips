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
// File Name          : addr_walk
// Module Description : Address decode and access policy over the whole 4 MB window.
//                      Probe set: a walking one and a walking zero over haddr[21:2]
//                      (every address bit rises and falls), reserved offsets inside
//                      a target stride, priority slots 0x400 / 0x800 / 0xFFC, the
//                      enable blocks of contexts >= NUM_CONTEXTS, pending word 256,
//                      the first reserved priority / pending / enable word and the
//                      first / last context's registers. Each probe is classified
//                      from the doc's address map and access table, then written
//                      with all-ones and read back from M, S and U mode (hprot
//                      4'h2 / 4'h0), with an M read-back proving a denied write
//                      changed nothing. PRIV_CHECK_EN=0: S and U behave as M.
//                      Also: hprot 4'hF / 4'hD decode as 4'h2 / 4'h0 (only bit 1
//                      counts), hsize 3'b100..3'b111 is denied in every build, and
//                      a misaligned word address lands on its containing word.
//----------------------------------------------------------------------------

`define PLIC_BASE     32'h00400000
`define PENDING_BASE  32'h00001000
`define ENABLE_BASE   32'h00002000
`define TARGET_BASE   32'h00200000

localparam AW_MAXP   = (1 << PRIO_BITS) - 1;
localparam AW_NWORDS = (NUM_SOURCES + 32) / 32;     // implemented pending / enable words

// Probe classes (doc address map).
localparam AW_PRIO   = 0;   // priority[1..NUM_SOURCES]
localparam AW_PEND   = 1;   // implemented pending word (read-only)
localparam AW_EN     = 2;   // implemented enable word of an implemented context
localparam AW_ENRSV  = 3;   // reserved word inside an implemented context's enable block
localparam AW_THR    = 4;   // threshold of an implemented context
localparam AW_CLAIM  = 5;   // claim/complete of an implemented context
localparam AW_TGTRSV = 6;   // reserved offset inside an implemented context's target stride
localparam AW_RSV    = 7;   // any other offset

task chk;
   input        cond;
   input [8*80-1:0] msg;
   begin
      if (cond !== 1'b1) begin
         $display("ERROR: %0s %t ns", msg, $time);
         error = error + 1;
      end
   end
endtask

function [31:0] aw_word_mask;
   input integer w;
   integer b;
   begin
      aw_word_mask = 32'h0;
      for (b = 0; b < 32; b = b + 1)
         if ((32*w + b >= 1) && (32*w + b <= NUM_SOURCES))
            aw_word_mask[b] = 1'b1;
   end
endfunction

function integer aw_class;
   input [21:0] off;
   integer ctx;
   begin
      if (off < 22'h001000)
         aw_class = ((off[11:2] >= 1) && (off[11:2] <= NUM_SOURCES)) ? AW_PRIO : AW_RSV;
      else if (off < 22'h002000)
         aw_class = (off[11:2] < AW_NWORDS) ? AW_PEND : AW_RSV;
      else if (off < 22'h003000) begin
         ctx = (off - 22'h002000) >> 7;
         if (ctx >= NUM_CONTEXTS)       aw_class = AW_RSV;
         else if (off[6:2] < AW_NWORDS) aw_class = AW_EN;
         else                           aw_class = AW_ENRSV;
      end else if (off >= 22'h200000) begin
         ctx = (off - 22'h200000) >> 12;
         if (ctx >= NUM_CONTEXTS)        aw_class = AW_RSV;
         else if (off[11:0] == 12'h000)  aw_class = AW_THR;
         else if (off[11:0] == 12'h004)  aw_class = AW_CLAIM;
         else                            aw_class = AW_TGTRSV;
      end else
         aw_class = AW_RSV;
   end
endfunction

// Context owning an enable / target offset (meaningful for those classes only).
function integer aw_ctx;
   input [21:0] off;
   begin
      if (off >= 22'h200000) aw_ctx = (off - 22'h200000) >> 12;
      else                   aw_ctx = (off - 22'h002000) >> 7;
   end
endfunction

// Access admitted? priv: 3 = M, 1 = S, 0 = U (decoded from hprot[1] / hsmode).
function aw_allowed;
   input [21:0] off;
   input  [1:0] priv;
   integer cl;
   begin
      cl = aw_class(off);
      if ((PRIV_CHECK_EN == 0) || (priv == 2'd3))
         aw_allowed = 1'b1;
      else if (priv == 2'd0)
         aw_allowed = 1'b0;
      else if ((cl == AW_EN) || (cl == AW_ENRSV) || (cl == AW_THR) || (cl == AW_CLAIM))
         aw_allowed = (SU_MODE_EN != 0) && (aw_ctx(off) % 2 == 1);
      else
         aw_allowed = 1'b1;
   end
endfunction

// Value an admitted read returns after an all-ones write (nothing pending).
function [31:0] aw_readback;
   input [21:0] off;
   integer cl;
   begin
      cl = aw_class(off);
      case (cl)
         AW_PRIO : aw_readback = AW_MAXP;
         AW_THR  : aw_readback = AW_MAXP;
         AW_EN   : aw_readback = aw_word_mask(off[6:2]);
         default : aw_readback = 32'h0;
      endcase
   end
endfunction

// One blocking transfer with explicit hprot / hsmode / hsize. A denied transfer
// must give the two-cycle ERROR, a denied read with hrdata = 0 in both cycles.
task aw_xfer;
   input        wr;
   input [31:0] addr;
   input [31:0] wdata;
   input  [3:0] prot;
   input        smode;
   input  [2:0] size;
   input        exp_err;
   input [31:0] exp_rdata;
   begin
      haddr  = addr;
      htrans = 2'b10;
      hwrite = wr;
      hsize  = size;
      hprot  = prot;
      hsmode = smode;
      @(posedge free_clk); #1;
      hwdata = wdata;
      haddr  = 32'h0;
      htrans = 2'b00;
      hwrite = 1'b0;
      hsize  = 3'b000;
      hprot  = 4'h2;
      hsmode = 1'b0;
      if (exp_err) begin
         if (!((hreadyout === 1'b0) && (hresp === 1'b1) && (wr || (hrdata === 32'h0)))) begin
            $display("ERROR: addr 0x%h wr=%b hprot=%h hsmode=%b hsize=%b: expected ERROR cycle 1 with hrdata=0, got rdy=%b resp=%b rdata=0x%h %t ns",
                     addr, wr, prot, smode, size, hreadyout, hresp, hrdata, $time);
            error = error + 1;
         end
         @(posedge free_clk); #1;
         if (!((hreadyout === 1'b1) && (hresp === 1'b1) && (wr || (hrdata === 32'h0)))) begin
            $display("ERROR: addr 0x%h wr=%b hprot=%h hsmode=%b hsize=%b: expected ERROR cycle 2 with hrdata=0, got rdy=%b resp=%b rdata=0x%h %t ns",
                     addr, wr, prot, smode, size, hreadyout, hresp, hrdata, $time);
            error = error + 1;
         end
      end else begin
         if (!((hreadyout === 1'b1) && (hresp === 1'b0) && (wr || (hrdata === exp_rdata)))) begin
            $display("ERROR: addr 0x%h wr=%b hprot=%h hsmode=%b hsize=%b: expected OKAY (read data 0x%h), got rdy=%b resp=%b rdata=0x%h %t ns",
                     addr, wr, prot, smode, size, exp_rdata, hreadyout, hresp, hrdata, $time);
            error = error + 1;
         end
      end
      @(posedge free_clk); #1;
   end
endtask

// Write all-ones, read back, M read-back, M restore to 0.
task aw_probe;
   input [21:0] off;
   input  [3:0] prot;
   input        smode;
   reg    [1:0] priv;
   reg          ok;
   begin
      priv = prot[1] ? (smode ? 2'd1 : 2'd3) : 2'd0;
      ok   = aw_allowed(off, priv);
      aw_xfer(1, `PLIC_BASE + off, 32'hFFFF_FFFF, prot, smode, 3'b010, ~ok, 32'h0);
      aw_xfer(0, `PLIC_BASE + off, 32'h0,         prot, smode, 3'b010, ~ok, aw_readback(off));
      aw_xfer(0, `PLIC_BASE + off, 32'h0,         4'h2, 1'b0,  3'b010, 1'b0, ok ? aw_readback(off) : 32'h0);
      aw_xfer(1, `PLIC_BASE + off, 32'h0,         4'h2, 1'b0,  3'b010, 1'b0, 32'h0);
   end
endtask

reg [21:0] aw_off [0:127];
integer    aw_n;
integer    i;
integer    b;
integer    m;
reg  [3:0] m_prot;
reg        m_smode;

task aw_add;
   input [21:0] off;
   begin
      aw_off[aw_n] = off;
      aw_n = aw_n + 1;
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(6) @(posedge free_clk); #1;

      // Probe set.
      aw_n = 0;
      for (b = 2; b <= 21; b = b + 1) aw_add(22'h1 << b);
      for (b = 2; b <= 21; b = b + 1) aw_add(22'h3FFFFC & ~(22'h1 << b));
      aw_add(22'h200008); aw_add(22'h200400); aw_add(22'h200800); aw_add(22'h200FFC);
      aw_add(22'h000400); aw_add(22'h000800); aw_add(22'h000FFC);
      aw_add(22'h001400);
      if (NUM_SOURCES < 1023) aw_add(4*(NUM_SOURCES+1));
      aw_add(`PENDING_BASE + 4*AW_NWORDS);
      aw_add(`ENABLE_BASE + 4*(AW_NWORDS-1));
      if (AW_NWORDS < 32) aw_add(`ENABLE_BASE + 4*AW_NWORDS);
      aw_add(`ENABLE_BASE + 32'h7C);
      aw_add(`ENABLE_BASE + 32'h80*(NUM_CONTEXTS-1));
      aw_add(`ENABLE_BASE + 32'h80*(NUM_CONTEXTS-1) + 32'h7C);
      aw_add(`TARGET_BASE + 32'h4);
      aw_add(`TARGET_BASE + 32'h1000*(NUM_CONTEXTS-1));
      aw_add(`TARGET_BASE + 32'h1000*(NUM_CONTEXTS-1) + 32'h4);
      aw_add(`TARGET_BASE + 32'h1000*(NUM_CONTEXTS-1) + 32'h8);
      if (NUM_CONTEXTS < 32) begin
         aw_add(`ENABLE_BASE + 32'h80*NUM_CONTEXTS);
         aw_add(`ENABLE_BASE + 32'h80*NUM_CONTEXTS + 4*(AW_NWORDS-1));
         aw_add(`TARGET_BASE + 32'h1000*NUM_CONTEXTS);
         aw_add(`TARGET_BASE + 32'h1000*NUM_CONTEXTS + 32'h4);
         aw_add(22'h002F80); aw_add(22'h002FFC);
      end

      $display(" ===============================================");
      $display("|    PROBE SET FROM M, S AND U MODE             |");
      $display(" ===============================================");

      for (m = 0; m < 3; m = m + 1) begin
         m_prot  = (m == 2) ? 4'h0 : 4'h2;
         m_smode = (m == 1);
         $display("----- hprot=%h hsmode=%b -----", m_prot, m_smode);
         for (i = 0; i < aw_n; i = i + 1)
            aw_probe(aw_off[i], m_prot, m_smode);
      end

      $display(" ===============================================");
      $display("|    HPROT 4'hF / 4'hD: ONLY BIT 1 COUNTS       |");
      $display(" ===============================================");

      for (m = 0; m < 4; m = m + 1) begin
         m_prot  = (m < 2) ? 4'hF : 4'hD;
         m_smode = m % 2;
         $display("----- hprot=%h hsmode=%b -----", m_prot, m_smode);
         aw_probe(22'h000004, m_prot, m_smode);
         aw_probe(22'h001000, m_prot, m_smode);
         aw_probe(22'h002000, m_prot, m_smode);
         aw_probe(22'h100000, m_prot, m_smode);
         aw_probe(22'h200000, m_prot, m_smode);
         aw_probe(22'h200008, m_prot, m_smode);
         aw_probe(`ENABLE_BASE + 32'h80*(NUM_CONTEXTS-1), m_prot, m_smode);
         aw_probe(`TARGET_BASE + 32'h1000*(NUM_CONTEXTS-1), m_prot, m_smode);
      end

      $display(" ===============================================");
      $display("|    HSIZE 3'b100..3'b111: DENIED               |");
      $display(" ===============================================");

      for (m = 4; m < 8; m = m + 1) begin
         aw_xfer(1, `PLIC_BASE + 32'h4, 32'h1, 4'h2, 1'b0, m, 1'b1, 32'h0);
         aw_xfer(1, `PLIC_BASE + `TARGET_BASE, 32'h1, 4'h2, 1'b0, m, 1'b1, 32'h0);
         aw_xfer(0, `PLIC_BASE + 32'h4, 32'h0, 4'h2, 1'b0, m, 1'b1, 32'h0);
         aw_xfer(0, `PLIC_BASE + 32'h4, 32'h0, 4'h2, 1'b0, 3'b010, 1'b0, 32'h0);
         aw_xfer(0, `PLIC_BASE + `TARGET_BASE, 32'h0, 4'h2, 1'b0, 3'b010, 1'b0, 32'h0);
      end

      $display(" ===============================================");
      $display("|    MISALIGNED WORD ADDRESS: CONTAINING WORD   |");
      $display(" ===============================================");

      // Priority / threshold written through a misaligned address, read aligned.
      aw_xfer(1, `PLIC_BASE + 32'h6,                 32'h1, 4'h2, 1'b0, 3'b010, 1'b0, 32'h0);
      aw_xfer(0, `PLIC_BASE + 32'h4,                 32'h0, 4'h2, 1'b0, 3'b010, 1'b0, 32'h1);
      aw_xfer(0, `PLIC_BASE + 32'h7,                 32'h0, 4'h2, 1'b0, 3'b010, 1'b0, 32'h1);
      aw_xfer(1, `PLIC_BASE + `TARGET_BASE + 32'h2,  32'h1, 4'h2, 1'b0, 3'b010, 1'b0, 32'h0);
      aw_xfer(0, `PLIC_BASE + `TARGET_BASE,          32'h0, 4'h2, 1'b0, 3'b010, 1'b0, 32'h1);
      aw_xfer(0, `PLIC_BASE + `TARGET_BASE + 32'h1,  32'h0, 4'h2, 1'b0, 3'b010, 1'b0, 32'h1);
      aw_xfer(1, `PLIC_BASE + 32'h4,                 32'h0, 4'h2, 1'b0, 3'b010, 1'b0, 32'h0);
      aw_xfer(1, `PLIC_BASE + `TARGET_BASE,          32'h0, 4'h2, 1'b0, 3'b010, 1'b0, 32'h0);

      // Source 1 pending but enabled nowhere: the misaligned pending read sees it,
      // the misaligned claim read finds nothing to claim (and must claim nothing).
      irq_src[1] = 1'b1;
      repeat(2) @(posedge free_clk); #1;
      irq_src[1] = 1'b0;
      aw_xfer(0, `PLIC_BASE + `PENDING_BASE + 32'h1, 32'h0, 4'h2, 1'b0, 3'b010, 1'b0, 32'h2);
      aw_xfer(0, `PLIC_BASE + `TARGET_BASE + 32'h5,  32'h0, 4'h2, 1'b0, 3'b010, 1'b0, 32'h0);
      aw_xfer(0, `PLIC_BASE + `PENDING_BASE,         32'h0, 4'h2, 1'b0, 3'b010, 1'b0, 32'h2);
      chk(dut.in_service_flat[1] === 1'b0, "misaligned claim read put source 1 in service");

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
