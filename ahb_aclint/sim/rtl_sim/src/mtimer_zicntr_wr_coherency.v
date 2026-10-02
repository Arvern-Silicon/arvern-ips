//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_zicntr_wr_coherency
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_zicntr_wr_coherency.v
// Module Description : A Zicntr time read CONCURRENT with an MTIME write must
//                      never return pre-write data once the write has landed.
//
//                      mtimer_zicntr_time covers the same side-band port but
//                      deliberately drives it on a QUIESCENT bus -- that is the
//                      only condition under which mtimer_active_o is the sole
//                      clock-keeper, which is what that test checks. A write in
//                      flight would invalidate its premise, so it cannot cover
//                      this and this test exists separately.
//
//                      THE BUG THIS GUARDS. time_val_o is a snapshot of
//                      mtime_rd_src latched on the grant DECISION edge, and
//                      mtime_rd_src selects the written value via
//                      mtime_*_pending -- a FLOP, so still low during the write
//                      strobe cycle itself. A grant decided on that one edge
//                      captured mtime_view, the pre-write LF-domain value, and
//                      handed it back as the post-write result. Observed in the
//                      core regression as `csrr time` returning the count from
//                      before an MTIME write that had already completed on the
//                      bus (17% of seeds on one timing variant).
//
//                      WHY A SWEEP. The window was exactly one cycle wide, so a
//                      single fixed alignment between the write and the read
//                      would sit in it only by luck. This walks time_req across
//                      the whole write transaction and asserts the invariant at
//                      every offset.
//
//                      THE INVARIANT is black-box and timing-based, not a check
//                      that the fix is present: if the grant pulse lands at or
//                      after the cycle the register write strobed, the value
//                      handed back must reflect that write. A grant that lands
//                      strictly earlier legitimately predates the write and is
//                      not checked.
//----------------------------------------------------------------------------

`define MTIME_LO_ADDR    32'h0040BFF8
`define MTIME_HI_ADDR    32'h0040BFFC
`define MTIMECMP_LO_ADDR 32'h00404000
`define MTIMECMP_HI_ADDR 32'h00404004

integer       d;
integer       cyc;
integer       strobe_cyc;
integer       gnt_cyc;
integer       checked;
integer       skipped;
reg  [63:0]   val;
reg  [31:0]   wr_val;

// Free-running cycle counter for the alignment comparison.
initial cyc = 0;
always @(posedge free_clk) cyc <= cyc + 1;

// Both monitors trigger on the SIGNAL, not on free_clk. hclk_i is gateable in
// this bench and the grant is a short pulse in that domain, so a free_clk-edge
// sampler misses it entirely -- which it did, silently reporting "never seen"
// while zicntr_time_read was completing normally a few lines away.

// The cycle the register write actually strobes inside the MTIMER. This is the
// edge on which a grant decision was previously poisoned.
initial strobe_cyc = -1;
always @(posedge tb_ahb_aclint.dut.u_mtimer.mtime_lo_wr) strobe_cyc = cyc;

// The cycle the grant pulse appears.
initial gnt_cyc = -1;
always @(posedge time_gnt) gnt_cyc = cyc;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(`LF_CYCLES(4)) @(posedge free_clk);

      // Park MTIMECMP out of reach: MTIME is thrown around below and a
      // spurious MTIP would only clutter the log.
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'hFFFFFFFF, 2, OK);
      repeat(`LF_CYCLES(6)) @(posedge free_clk);

      ahb_write(1, MACHINE, `MTIME_HI_ADDR, 32'h00000000, 2, OK);
      repeat(`LF_CYCLES(4)) @(posedge free_clk);

      $display("");
      $display(" ==================================================================");
      $display("|  ZICNTR READ CONCURRENT WITH AN MTIME WRITE                     |");
      $display(" ==================================================================");
      $display("");
      $display("   A grant at or after the write strobe must not return pre-write");
      $display("   data. time_req is walked across the write transaction.");
      $display("");

      checked = 0;
      skipped = 0;

      for (d = 0; d <= 8; d = d + 1) begin
         // Each round writes a strictly larger value, so "stale" is unambiguous:
         // MTIME only counts UP from what was written, so anything below the
         // written value can only be pre-write data.
         wr_val     = 32'h10000000 + (d << 24);
         strobe_cyc = -1;
         gnt_cyc    = -1;

         fork
            ahb_write(1, MACHINE, `MTIME_LO_ADDR, wr_val, 2, OK);
            begin
               repeat (d) @(negedge free_clk);
               zicntr_time_read(val, "concurrent-with-write");
            end
         join

         if (strobe_cyc < 0 || gnt_cyc < 0) begin
            $display("ERROR: offset %0d -- write strobe or grant never seen"
                     ,d);
            error = error + 1;
         end
         else if (gnt_cyc <= strobe_cyc) begin
            // The snapshot is latched on the grant DECISION edge, one cycle
            // before the pulse -- so a pulse at the strobe cycle was decided the
            // cycle before it, and genuinely predates the write. Returning the
            // old value there is correct, not a defect. The poisoned case is a
            // pulse STRICTLY after the strobe, whose decision lands exactly on
            // it: that is the original failure (strobe 94, pulse 95).
            $display("INFO:  offset %0d -- grant(%0d) decided before write strobe(%0d), not applicable",
                     d, gnt_cyc, strobe_cyc);
            skipped = skipped + 1;
         end
         else begin
            checked = checked + 1;
            if (val[31:0] < wr_val) begin
               $display("ERROR: offset %0d -- grant(%0d) decided at/after write strobe(%0d) but",
                        d, gnt_cyc, strobe_cyc);
               $display("       time_val = 0x%h, BELOW the 0x%h just written -- the snapshot",
                        val[31:0], wr_val);
               $display("       was taken before the pending-write forwarding engaged %t ns", $time);
               error = error + 1;
            end
            else
               $display("PASS:  offset %0d -- grant(%0d) > strobe(%0d), time_val = 0x%h %t ns",
                        d, gnt_cyc, strobe_cyc, val[31:0], $time);
         end

         // Let the write drain to the LF domain before the next round, so each
         // round starts from a settled state rather than inheriting a pending.
         repeat(`LF_CYCLES(6)) @(posedge free_clk);
      end

      $display("");
      if (checked == 0) begin
         $display("ERROR: no offset produced a grant at or after the write strobe --");
         $display("       the sweep never reached the window it exists to cover %t ns", $time);
         error = error + 1;
      end
      else
         $display("INFO:  %0d offset(s) exercised the invariant, %0d not applicable",
                  checked, skipped);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
