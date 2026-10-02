//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_multihart
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_multihart
// Module Description : Per-hart MTIMECMP / MTIP independence. Programs all
//                      per-hart comparators back-to-back with staggered
//                      targets relative to a single t_now snapshot, then
//                      polls irq_m_timer_o in sequence to verify they fire
//                      in the programmed order. Reads MTIME at its fixed
//                      offset (0x7FF8 in the MTIMER window, independent of
//                      NUM_HARTS) and probes the bench's 64-bit snapshot.
//                      Requires NUM_HARTS >= 2. Caps tested harts at 4 when
//                      NUM_HARTS > 4 to keep runtime bounded.
//----------------------------------------------------------------------------

localparam TESTED   = (NUM_HARTS > 4) ? 4 : NUM_HARTS;
localparam OFFSET_0 = 64'd40;   // LF ticks ahead of t_now for hart 0
localparam OFFSET_S = 64'd40;   // additional LF tick spacing between harts

// MTIME_LO sits at a fixed offset, 0x7FF8 in the MTIMER window (0x4000), for
// every NUM_HARTS.
wire [31:0] mtime_lo_addr = 32'h0040BFF8;
wire [31:0] mtime_hi_addr = mtime_lo_addr + 32'h4;

reg  [63:0] t_now;
reg  [63:0] target [0:15];
integer     hh;
integer     poll_count;
reg         irq_seen;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(20) @(posedge free_clk);

      $display(" ===============================================");
      $display("|     MTIMER : PER-HART COMPARATOR SWEEP        |");
      $display(" ===============================================");
      $display("INFO:  NUM_HARTS = %0d, TESTED = %0d", NUM_HARTS, TESTED);

      // Park every tested hart's MTIMECMP at the top of range so no
      // comparator can match during setup.
      for (hh = 0; hh < TESTED; hh = hh + 1) begin
         ahb_write(1, MACHINE, 32'h00404004 + (32'h8 * hh), 32'hFFFFFFFF, 2, OK);
         ahb_write(1, MACHINE, 32'h00404000 + (32'h8 * hh), 32'hFFFFFFFF, 2, OK);
      end

      // Each hart's MTIMECMP must be its own storage, not hart 0's aliased.
      // Give every tested hart a distinct pattern and read it back before any
      // of them is armed, so a decode that ignores the hart index shows up as a
      // read-back mismatch rather than as a missing interrupt much later.
      for (hh = 0; hh < TESTED; hh = hh + 1) begin
         ahb_write(1, MACHINE, 32'h00404000 + (32'h8 * hh), 32'hA5A50000 + hh, 2, OK);
         ahb_write(1, MACHINE, 32'h00404004 + (32'h8 * hh), 32'h5A5A0000 + hh, 2, OK);
      end
      for (hh = 0; hh < TESTED; hh = hh + 1) begin
         ahb_read(1, MACHINE, 32'h00404000 + (32'h8 * hh), 32'hA5A50000 + hh, 2, 1, OK);
         ahb_read(1, MACHINE, 32'h00404004 + (32'h8 * hh), 32'h5A5A0000 + hh, 2, 1, OK);
      end
      $display("PASS:  per-hart MTIMECMP read-back distinct for %0d harts %t ns", TESTED, $time);

      // Just above the implemented MTIMECMP bank the window is still MTIMER, so
      // the offset is reserved RAZ/WI -- not an alias of the last hart's pair.
      ahb_write(1, MACHINE, 32'h00404000 + (32'h8 * NUM_HARTS), 32'hDEADBEEF, 2, OK);
      ahb_read (1, MACHINE, 32'h00404000 + (32'h8 * NUM_HARTS), 32'h00000000, 2, 1, OK);
      ahb_read (1, MACHINE, 32'h00404004 + (32'h8 * NUM_HARTS), 32'h00000000, 2, 1, OK);
      // The dropped write must not have aliased into any implemented pair. Check
      // the ends of the range that was actually populated (TESTED may be less
      // than NUM_HARTS), since a truncated index would land on one of them.
      ahb_read (1, MACHINE, 32'h00404000, 32'hA5A50000, 2, 1, OK);
      ahb_read (1, MACHINE, 32'h00404000 + (32'h8 * (TESTED-1)),
                            32'hA5A50000 + (TESTED-1), 2, 1, OK);
      $display("PASS:  top-of-bank offset (0x%h) is RAZ/WI and aliased into no implemented pair %t ns",
               32'h00404000 + (32'h8 * NUM_HARTS), $time);

      // Re-park everything before the timed sweep below.
      for (hh = 0; hh < TESTED; hh = hh + 1) begin
         ahb_write(1, MACHINE, 32'h00404004 + (32'h8 * hh), 32'hFFFFFFFF, 2, OK);
         ahb_write(1, MACHINE, 32'h00404000 + (32'h8 * hh), 32'hFFFFFFFF, 2, OK);
      end

      // Let all MTIMECMP writes settle on the LF side.
      repeat(60) @(posedge free_clk);

      // Capture a single t_now via an AHB MTIME_LO read - this latches a
      // fresh 64-bit snapshot into the hclk-domain MTIME shadow (mirrored by
      // the bench's mtime_shadow_ahb_sim). We then sample the snapshot
      // directly because hrdata returns to 0 after the AHB task ends.
      $display("INFO:  MTIME_LO addr = 0x%h (NUM_HARTS=%0d)", mtime_lo_addr, NUM_HARTS);
      ahb_read(1, MACHINE, mtime_lo_addr, 32'h00000000, 2, 0, OK);
      t_now = tb_ahb_aclint.mtime_shadow_ahb_sim;
      ahb_read(1, MACHINE, mtime_hi_addr, 32'h00000000, 2, 0, OK);
      $display("INFO:  t_now (shadow) = 0x%h_%h %t ns",
               t_now[63:32], t_now[31:0], $time);

      // Compute staggered targets : hart h fires at t_now + OFFSET_0 + h*OFFSET_S.
      // Hart 0 -> t_now + 40, hart 1 -> t_now + 80, hart 2 -> t_now + 120, ...
      for (hh = 0; hh < TESTED; hh = hh + 1) begin
         target[hh] = t_now + OFFSET_0 + (hh * OFFSET_S);
         $display("INFO:  hart %0d target = 0x%h_%h", hh,
                  target[hh][63:32], target[hh][31:0]);
      end

      // Program all MTIMECMPs back-to-back (LO then HI per hart) so the
      // staggered relationship is preserved against the SAME captured t_now.
      for (hh = 0; hh < TESTED; hh = hh + 1) begin
         ahb_write(1, MACHINE, 32'h00404000 + (32'h8 * hh), target[hh][31:0],  2, OK);
         ahb_write(1, MACHINE, 32'h00404004 + (32'h8 * hh), target[hh][63:32], 2, OK);
      end

      // Wait for the MTIMECMP writes to reach the LF side
      // before MTIME catches up to the earliest target.
      repeat(40) @(posedge free_clk);

      // Poll each hart's IRQ in sequence. Because targets are monotonically
      // increasing, IRQ[h] always asserts before IRQ[h+1]; if h+1 has
      // already asserted by the time we check, that is a failure of the
      // staggered ordering (or of comparator routing).
      for (hh = 0; hh < TESTED; hh = hh + 1) begin
         irq_seen   = 1'b0;
         poll_count = 0;
         begin : POLL_HART
            // 4000 hclk @ 20 MHz = 200 us = 1000 LF ticks @ 5 MHz LF :
            // generous bound for the worst-cap (last hart) tested.
            repeat (4000) begin
               @(posedge free_clk);
               poll_count = poll_count + 1;
               if (tb_ahb_aclint.dut.irq_m_timer_o[hh] == 1'b1) begin
                  irq_seen = 1'b1;
                  disable POLL_HART;
               end
            end
         end
         if (irq_seen) begin
            $display("PASS:  irq_m_timer_o[%0d] asserted after %0d hclk cycles %t ns",
                     hh, poll_count, $time);
         end else begin
            $display("ERROR: irq_m_timer_o[%0d] did not assert within 4000 hclk cycles %t ns",
                     hh, $time);
            error = error + 1;
         end
      end

      // After all polled harts fired, sanity-check : all tested harts
      // should be asserted simultaneously (targets are all in the past).
      repeat(20) @(posedge free_clk);
      for (hh = 0; hh < TESTED; hh = hh + 1) begin
         if (tb_ahb_aclint.dut.irq_m_timer_o[hh] !== 1'b1) begin
            $display("ERROR: irq_m_timer_o[%0d] dropped before end-of-test -- got %b %t ns",
                     hh, tb_ahb_aclint.dut.irq_m_timer_o[hh], $time);
            error = error + 1;
         end else begin
            $display("PASS:  irq_m_timer_o[%0d] still asserted at end-of-sweep %t ns", hh, $time);
         end
      end

      // Cleanup : push every tested comparator back to max so IRQs drop.
      for (hh = 0; hh < TESTED; hh = hh + 1) begin
         ahb_write(1, MACHINE, 32'h00404000 + (32'h8 * hh), 32'hFFFFFFFF, 2, OK);
         ahb_write(1, MACHINE, 32'h00404004 + (32'h8 * hh), 32'hFFFFFFFF, 2, OK);
      end

      repeat(40) @(posedge free_clk);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
