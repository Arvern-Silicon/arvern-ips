//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_hart_sweep
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_hart_sweep.v
// Module Description : EVERY HART, NOT A SAMPLE OF THEM. mtimer_multihart caps
//                      its sweep at 4 harts and mtimer_hart_hi probes two; this
//                      walks all NUM_HARTS (meant for 16, also run at 2):
//
//                        1. MSIP[h] set / clear per hart: only bit h of
//                           irq_m_software_o follows, and a read of every MSIP
//                           shows only MSIP[h] set.
//                             ahb_aclint.md MSWI: "bit [0] =
//                             irq_m_software_o[hart], read-write level, reset 0.
//                             Bits [31:1] RAZ/WI."
//                             ACLINT 3.2: "A machine-level software interrupt
//                             for a HART is pending or cleared by writing 1 or
//                             0 respectively to the corresponding MSIP
//                             register."
//                        2. A distinct MTIMECMP LO/HI pattern per hart, all
//                           written first and read back after (no aliasing,
//                           no LO/HI swap).
//                             ahb_aclint.md: "MTIMECMP read-back returns the
//                             register as written -- single-cycle"
//                        3. Deadlines staggered in a permuted (non-index)
//                           order. While no MTIMECMP write is in flight, every
//                           negedge checks the whole irq_m_timer_o vector
//                           against (read view >= MTIMECMP[h]) per hart, so
//                           each bit must rise exactly when its compare is met
//                           and no other bit may move with it; the rise order
//                           must equal the programmed order.
//                             ACLINT 2.3: "The machine-level timer interrupt of
//                             a HART is pending whenever MTIME is greater than
//                             or equal to the value in the corresponding
//                             MTIMECMP register"
//                             ahb_aclint.md MTIP and the wake:
//                             "irq_m_timer_o compares the read view against the
//                             hclk-side register"
//                        4. Clear each hart in turn (disarm): its bit drops
//                           within one hclk, the not-yet-cleared ones stay up.
//                             ahb_aclint.md: "MTIP (irq_m_timer_o) ... follows
//                             a write within one hclk."
//
//                      The read view is probed as u_mtimer.mtime_rd_src, the
//                      same net mtimer_cmp_wrap uses. Requires NUM_HARTS >= 2.
//----------------------------------------------------------------------------

localparam [31:0] HS_MSIP_BASE  = 32'h00400000;
localparam [31:0] HS_CMP_BASE   = 32'h00404000;
localparam [31:0] HS_MTIME_LO   = 32'h0040BFF8;
localparam [31:0] HS_MTIME_HI   = 32'h0040BFFC;
localparam integer HS_OFFSET0   = 40 + 2 * NUM_HARTS;  // LF ticks to the first deadline
localparam integer HS_SPACING   = 6;                   // LF ticks between deadlines

reg  [63:0]          hs_cmp       [0:15];   // model of every programmed MTIMECMP
integer              hs_order     [0:15];   // hs_order[p] = hart expiring p-th
integer              hs_rise_hart [0:15];   // observed rise order
integer              hs_rise_cnt;
integer              hs_mon_err;
integer              hs_mj;
reg                  hs_mon_en;
reg  [NUM_HARTS-1:0] hs_exp;
reg  [NUM_HARTS-1:0] hs_prev;
reg  [NUM_HARTS-1:0] hs_new;
reg  [63:0]          hs_view;
reg  [NUM_HARTS-1:0] hs_one;

integer              hh;
integer              kk;
integer              pp;
integer              hs_step;
integer              hs_guard;
reg                  hs_seen;
reg  [63:0]          hs_t_now;
reg  [63:0]          hs_tgt;
reg  [31:0]          hs_lo;
reg  [31:0]          hs_hi;
reg                  hs_r1;
reg                  hs_r2;
reg  [31:0]          hs_rd;
integer              hs_w;

// Whole-vector MTIP monitor. Sampled at the negedge: irq_m_timer_o is a
// combinational compare of registers clocked on the rising edge.
initial begin
   hs_mon_en   = 1'b0;
   hs_mon_err  = 0;
   hs_rise_cnt = 0;
   hs_prev     = {NUM_HARTS{1'b0}};
   hs_one      = {{NUM_HARTS{1'b0}}} | 1'b1;
   for (hs_mj = 0; hs_mj < 16; hs_mj = hs_mj + 1) begin
      hs_cmp[hs_mj]       = 64'hFFFFFFFF_FFFFFFFF;
      hs_rise_hart[hs_mj] = -1;
   end
end

always @(negedge free_clk) begin
   if (hs_mon_en) begin
      hs_view = tb_ahb_aclint.dut.u_mtimer.mtime_rd_src;
      for (hs_mj = 0; hs_mj < NUM_HARTS; hs_mj = hs_mj + 1)
         hs_exp[hs_mj] = (hs_view >= hs_cmp[hs_mj]);
      if (irq_m_timer !== hs_exp) begin
         hs_mon_err = hs_mon_err + 1;
         if (hs_mon_err <= 8)
            $display("ERROR: irq_m_timer_o = %b, expected %b for read view 0x%h_%h %t ns",
                     irq_m_timer, hs_exp, hs_view[63:32], hs_view[31:0], $time);
         error = error + 1;
      end
      hs_new = irq_m_timer & ~hs_prev;
      for (hs_mj = 0; hs_mj < NUM_HARTS; hs_mj = hs_mj + 1) begin
         if (hs_new[hs_mj] === 1'b1) begin
            if (hs_rise_cnt < 16) hs_rise_hart[hs_rise_cnt] = hs_mj;
            hs_rise_cnt = hs_rise_cnt + 1;
         end
      end
      hs_prev = irq_m_timer;
   end
end

// Raw single transfer; samples the bus outputs at the negedge. Returns the read
// data seen on the completing cycle.
task hs_xfer;
   input         wr;
   input  [31:0] addr;
   input  [31:0] wdata;
   output        resp_p1;
   output        resp_end;
   output [31:0] rdata;
   output integer waits;
   begin
      haddr  = addr;
      htrans = 2'b10;
      hwrite = wr;
      hsize  = 3'b010;
      hprot  = 4'h2;
      hsmode = 1'b0;
      @(posedge free_clk);
      #1;
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hwrite = 1'b0;
      hprot  = 4'h0;
      hsize  = 3'b000;
      hwdata = wdata;
      waits  = 0;
      @(negedge free_clk);
      resp_p1 = hresp;
      while ((hreadyout !== 1'b1) && (waits < `LF_CYCLES(4) + 16)) begin
         @(negedge free_clk);
         waits = waits + 1;
      end
      resp_end = hresp;
      rdata    = hrdata;
      @(posedge free_clk);
      #1;
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);

      if (NUM_HARTS < 2) begin
         tb_skip_finish("mtimer_hart_sweep requires NUM_HARTS >= 2 (run at nh2 / nh16)");
      end

      repeat(`LF_CYCLES(5)) @(posedge free_clk);

      $display(" ===============================================");
      $display("|   HART SWEEP : MSIP SET / CLEAR PER HART      |");
      $display(" ===============================================");
      $display("INFO:  NUM_HARTS = %0d", NUM_HARTS);

      for (hh = 0; hh < NUM_HARTS; hh = hh + 1) begin
         // All-ones: bits [31:1] are RAZ/WI, so the read-back is 1.
         ahb_write(1, MACHINE, HS_MSIP_BASE + 4*hh, 32'hFFFFFFFF, 2, OK);
         repeat(2) @(negedge free_clk);
         if (irq_m_software !== (hs_one << hh)) begin
            $display("ERROR: MSIP[%0d]=1 -> irq_m_software_o = %b, expected only bit %0d %t ns",
                     hh, irq_m_software, hh, $time);
            error = error + 1;
         end
         for (kk = 0; kk < NUM_HARTS; kk = kk + 1)
            ahb_read(1, MACHINE, HS_MSIP_BASE + 4*kk, (kk == hh) ? 32'h1 : 32'h0, 2, 1, OK);

         ahb_write(1, MACHINE, HS_MSIP_BASE + 4*hh, 32'h00000000, 2, OK);
         repeat(2) @(negedge free_clk);
         if (irq_m_software !== {NUM_HARTS{1'b0}}) begin
            $display("ERROR: MSIP[%0d]=0 -> irq_m_software_o = %b, expected all clear %t ns",
                     hh, irq_m_software, $time);
            error = error + 1;
         end
         ahb_read(1, MACHINE, HS_MSIP_BASE + 4*hh, 32'h0, 2, 1, OK);
      end

      // Every odd hart at once, then clear them all.
      for (hh = 1; hh < NUM_HARTS; hh = hh + 2)
         ahb_write(1, MACHINE, HS_MSIP_BASE + 4*hh, 32'h00000001, 2, OK);
      repeat(2) @(negedge free_clk);
      for (hh = 0; hh < NUM_HARTS; hh = hh + 1) begin
         if (irq_m_software[hh] !== hh[0]) begin
            $display("ERROR: odd-hart pattern -- irq_m_software_o[%0d] = %b %t ns",
                     hh, irq_m_software[hh], $time);
            error = error + 1;
         end
         ahb_read(1, MACHINE, HS_MSIP_BASE + 4*hh, {31'h0, hh[0]}, 2, 1, OK);
      end
      for (hh = 1; hh < NUM_HARTS; hh = hh + 2)
         ahb_write(1, MACHINE, HS_MSIP_BASE + 4*hh, 32'h00000000, 2, OK);
      repeat(2) @(negedge free_clk);
      if (irq_m_software !== {NUM_HARTS{1'b0}}) begin
         $display("ERROR: irq_m_software_o = %b after clearing every MSIP %t ns", irq_m_software, $time);
         error = error + 1;
      end else begin
         $display("PASS:  MSIP set / clear independent on all %0d harts %t ns", NUM_HARTS, $time);
      end

      $display("");
      $display(" ===============================================");
      $display("|   HART SWEEP : DISTINCT MTIMECMP READ-BACK    |");
      $display(" ===============================================");

      // Per-half, per-hart distinct: LO carries 0xC0DE, HI 0x7E, both carry the
      // hart index twice, so an alias or a LO/HI swap reads back wrong. HI is far
      // above MTIME, so none of these can raise MTIP.
      for (hh = 0; hh < NUM_HARTS; hh = hh + 1) begin
         ahb_write(1, MACHINE, HS_CMP_BASE + 8*hh + 4, 32'h7E000000 | (hh << 16) | (32'hF0 + hh), 2, OK);
         ahb_write(1, MACHINE, HS_CMP_BASE + 8*hh,     32'hC0DE0000 | (hh << 8)  | (32'h0F ^ hh), 2, OK);
      end
      for (hh = 0; hh < NUM_HARTS; hh = hh + 1) begin
         ahb_read(1, MACHINE, HS_CMP_BASE + 8*hh,     32'hC0DE0000 | (hh << 8)  | (32'h0F ^ hh), 2, 1, OK);
         ahb_read(1, MACHINE, HS_CMP_BASE + 8*hh + 4, 32'h7E000000 | (hh << 16) | (32'hF0 + hh), 2, 1, OK);
      end
      @(negedge free_clk);
      if (irq_m_timer !== {NUM_HARTS{1'b0}}) begin
         $display("ERROR: irq_m_timer_o = %b with every MTIMECMP far in the future %t ns", irq_m_timer, $time);
         error = error + 1;
      end

      // Park everything (LO first: the intermediate {old HI, all-ones} is still
      // far in the future).
      // Each LO also passes through all-zeros under an all-ones HI (still far in the
      // future), held long enough to reach the compare copy taken on the LF tick, so
      // every LO bit of every hart's MTIMECMP rises and falls in both copies.
      for (hh = 0; hh < NUM_HARTS; hh = hh + 1) begin
         ahb_write(1, MACHINE, HS_CMP_BASE + 8*hh,     32'hFFFFFFFF, 2, OK);
         ahb_write(1, MACHINE, HS_CMP_BASE + 8*hh + 4, 32'hFFFFFFFF, 2, OK);
         ahb_write(1, MACHINE, HS_CMP_BASE + 8*hh,     32'h00000000, 2, OK);
         ahb_read (1, MACHINE, HS_CMP_BASE + 8*hh,     32'h00000000, 2, 1, OK);
         repeat(`LF_CYCLES(2)) @(posedge free_clk);  // let the LF-tick compare copy take it
         ahb_write(1, MACHINE, HS_CMP_BASE + 8*hh,     32'hFFFFFFFF, 2, OK);
      end
      for (hh = 0; hh < NUM_HARTS; hh = hh + 1) begin
         ahb_read(1, MACHINE, HS_CMP_BASE + 8*hh,     32'hFFFFFFFF, 2, 1, OK);
         ahb_read(1, MACHINE, HS_CMP_BASE + 8*hh + 4, 32'hFFFFFFFF, 2, 1, OK);
      end

      $display("");
      $display(" ===============================================");
      $display("|   HART SWEEP : EXPIRY IN A PERMUTED ORDER     |");
      $display(" ===============================================");

      // Expiry order hart = (p*step + 3) mod N, step coprime with N.
      hs_step = ((NUM_HARTS % 7) == 0) ? 5 : 7;
      for (pp = 0; pp < NUM_HARTS; pp = pp + 1)
         hs_order[pp] = (pp * hs_step + 3) % NUM_HARTS;

      hs_xfer(0, HS_MTIME_LO, 32'h0, hs_r1, hs_r2, hs_lo, hs_w);
      hs_xfer(0, HS_MTIME_HI, 32'h0, hs_r1, hs_r2, hs_hi, hs_w);
      hs_t_now = {hs_hi, hs_lo};
      $display("INFO:  t_now = 0x%h_%h %t ns", hs_t_now[63:32], hs_t_now[31:0], $time);

      for (pp = 0; pp < NUM_HARTS; pp = pp + 1) begin
         hh     = hs_order[pp];
         hs_tgt = hs_t_now + HS_OFFSET0 + pp * HS_SPACING;
         // From all-ones, HI then LO keeps the intermediate {new HI, all-ones}
         // at or above the new comparand.
         ahb_write(1, MACHINE, HS_CMP_BASE + 8*hh + 4, hs_tgt[63:32], 2, OK);
         ahb_write(1, MACHINE, HS_CMP_BASE + 8*hh,     hs_tgt[31:0],  2, OK);
         hs_cmp[hh] = hs_tgt;
         $display("INFO:  order %0d -> hart %0d, deadline 0x%h_%h", pp, hh, hs_tgt[63:32], hs_tgt[31:0]);
      end
      repeat(2) @(negedge free_clk);

      if (tb_ahb_aclint.dut.u_mtimer.mtime_rd_src >= hs_cmp[hs_order[0]]) begin
         $display("ERROR: programming took longer than HS_OFFSET0 -- the first deadline already passed %t ns", $time);
         error = error + 1;
      end

      hs_prev   = irq_m_timer;
      hs_mon_en = 1'b1;

      for (pp = 0; pp < NUM_HARTS; pp = pp + 1) begin
         hh       = hs_order[pp];
         hs_seen  = 1'b0;
         hs_guard = 0;
         while ((hs_seen == 1'b0) && (hs_guard < `LF_CYCLES(HS_OFFSET0 + HS_SPACING + 10))) begin
            @(negedge free_clk);
            hs_guard = hs_guard + 1;
            if (irq_m_timer[hh] === 1'b1) hs_seen = 1'b1;
         end
         if (!hs_seen) begin
            $display("ERROR: irq_m_timer_o[%0d] (order %0d) never asserted %t ns", hh, pp, $time);
            error = error + 1;
         end else begin
            $display("PASS:  irq_m_timer_o[%0d] asserted (order %0d) %t ns", hh, pp, $time);
         end
      end

      repeat(4) @(negedge free_clk);
      hs_mon_en = 1'b0;

      if (hs_rise_cnt != NUM_HARTS) begin
         $display("ERROR: monitor saw %0d MTIP rises, expected exactly %0d %t ns", hs_rise_cnt, NUM_HARTS, $time);
         error = error + 1;
      end
      for (pp = 0; (pp < NUM_HARTS) && (pp < hs_rise_cnt); pp = pp + 1) begin
         if (hs_rise_hart[pp] != hs_order[pp]) begin
            $display("ERROR: rise %0d was hart %0d, programmed order says hart %0d %t ns",
                     pp, hs_rise_hart[pp], hs_order[pp], $time);
            error = error + 1;
         end
      end
      if (hs_mon_err == 0 && hs_rise_cnt == NUM_HARTS)
         $display("PASS:  every MTIP bit rose exactly at its compare, in order, and alone %t ns", $time);

      $display("");
      $display(" ===============================================");
      $display("|   HART SWEEP : CLEAR EACH HART                |");
      $display(" ===============================================");

      for (hh = 0; hh < NUM_HARTS; hh = hh + 1) begin
         // HI to all-ones alone already puts the comparand above MTIME.
         ahb_write(1, MACHINE, HS_CMP_BASE + 8*hh + 4, 32'hFFFFFFFF, 2, OK);
         @(negedge free_clk);
         for (kk = 0; kk < NUM_HARTS; kk = kk + 1)
            hs_exp[kk] = (kk > hh);
         if (irq_m_timer !== hs_exp) begin
            $display("ERROR: after disarming hart %0d irq_m_timer_o = %b, expected %b %t ns",
                     hh, irq_m_timer, hs_exp, $time);
            error = error + 1;
         end
         ahb_write(1, MACHINE, HS_CMP_BASE + 8*hh, 32'hFFFFFFFF, 2, OK);
      end
      repeat(2) @(negedge free_clk);
      if (irq_m_timer !== {NUM_HARTS{1'b0}}) begin
         $display("ERROR: irq_m_timer_o = %b after every hart was disarmed %t ns", irq_m_timer, $time);
         error = error + 1;
      end else begin
         $display("PASS:  each MTIP cleared on its own disarm, the others unaffected %t ns", $time);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
