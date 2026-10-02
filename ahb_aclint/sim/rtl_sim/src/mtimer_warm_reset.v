//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_warm_reset
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_warm_reset.v
// Module Description : ASYMMETRIC RESET ASSERTION across the hclk<->clk_lf
//                      boundary. The whole point of putting MTIME in the LF
//                      domain is that it survives a reset of the AHB domain, and
//                      doc/ahb_aclint.md states the two resets are independent
//                      -- so hresetn_i asserting alone, at runtime, with
//                      clk_lf_i free-running, is a supported scenario.
//
//                      Every other test in the suite resets once at POR with
//                      BOTH resets asserted together, the one shape that cannot
//                      expose a reset-domain crossing. This test covers four
//                      that can:
//
//                        1. hresetn_i alone, held several clk_lf_i periods.
//                           MTIME must keep counting from where it was; a
//                           reset-induced change on the load request must not
//                           be mistaken for a write.
//                        2. MTIMECMP across the same reset -- the OPPOSITE
//                           expectation to MTIME. It must come back disarmed.
//                        3. hresetn_i alone, held SHORTER than one clk_lf_i
//                           period. The write path must not be left half-way
//                           through a crossing.
//                        4. resetn_lf_i alone. MTIME legitimately returns to
//                           zero, but the write path must come back usable.
//
//                      Checks are written against observable behaviour -- MTIME
//                      and MTIMECMP values, a subsequent write completing --
//                      rather than against any particular internal encoding.
//
//                      UNDER LF_SYNC_EN=1 THE EXPECTATION INVERTS. There is no
//                      second domain: MTIME is paced by the tick on hclk_aon
//                      and reset by hresetn like everything else, so a warm
//                      reset of the AHB domain legitimately RESTARTS the
//                      timebase. That is the documented cost of synchronous
//                      mode, and it is asserted here rather than skipped -- if
//                      the async build ever starts behaving this way, or the
//                      sync build stops, that is a real regression either way.
//                      The LF-only reset phase is skipped in sync mode: with
//                      resetn_lf tied off there is nothing to assert.
//----------------------------------------------------------------------------

reg [63:0] rb;
reg [63:0] before_rst;
reg [63:0] target;
reg [63:0] cmp_rb;
integer    ii;
integer    phantom_ld;
integer    busy_wait;
reg        watching;

`define MTIME_LO_ADDR    32'h0040BFF8
`define MTIME_HI_ADDR    32'h0040BFFC
`define MTIMECMP_LO_ADDR 32'h00404000
`define MTIMECMP_HI_ADDR 32'h00404004

// Direct visibility of the LF-side capture strobes. The value checks below are
// the real pass/fail criteria -- this monitor exists so that a failure names
// its own cause instead of leaving "MTIME is wrong" to be bisected by hand.
initial
   begin
      phantom_ld = 0;
      watching   = 1'b0;
      forever begin
         @(posedge clk_lf);
         if (watching && (tb_ahb_aclint.dut.u_mtimer.load_ack_lf === 1'b1)) begin
            phantom_ld = phantom_ld + 1;
            $display("INFO:  phantom LF load of MTIME with no software write %t ns", $time);
         end
      end
   end

// Read a coherent 64-bit MTIME (LO latches the upper half, HI returns it;
// the TB mirror holds the reconstructed snapshot).
task read_mtime;
   output [63:0] val;
   begin
      ahb_read(1, MACHINE, `MTIME_LO_ADDR, 32'h00000000, 2, 0, OK);
      ahb_read(1, MACHINE, `MTIME_HI_ADDR, 32'h00000000, 2, 0, OK);
      val = tb_ahb_aclint.mtime_shadow_ahb_sim;
   end
endtask

// Wait, bounded, for any in-flight write to finish crossing. Returns the number
// of free_clk cycles waited, so a stuck pending is reported by the caller rather
// than hanging the simulation until the watchdog fires.
//
// Waits for wr_pending to RISE first. ahb_write returns while the data phase is
// still in flight, so polling only for the fall finds it still low and returns
// immediately -- which reads as "the write landed" when nothing has happened.
// Call sites here always issue two writes, which masks it; do not rely on that.
task wait_mtime_idle;
   output integer waited;
   begin
      waited = 0;
      while ((tb_ahb_aclint.dut.u_mtimer.wr_pending === 1'b0) &&
             (waited < `LF_CYCLES(2))) begin
         @(posedge free_clk);
         waited = waited + 1;
      end
      while ((tb_ahb_aclint.dut.u_mtimer.wr_pending === 1'b1) &&
             (waited < `LF_CYCLES(40))) begin
         @(posedge free_clk);
         waited = waited + 1;
      end
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(100) @(posedge free_clk);

      // Park MTIMECMP out of reach: a phantom MTIME load lands all-ones and
      // would otherwise raise MTIP, which is a second symptom of the same
      // fault and only clutters the log.
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'hFFFFFFFF, 2, OK);
      wait_mtime_idle(busy_wait);

      $display(" ===============================================");
      $display("|   WARM RESET : hresetn ALONE, LONG            |");
      $display(" ===============================================");

      // A distinctive MTIME, so a phantom load is unmistakable rather than
      // blending into the ordinary count.
      target = 64'h00000055_20000000;
      ahb_write(1, MACHINE, `MTIME_HI_ADDR, target[63:32], 2, OK);
      ahb_write(1, MACHINE, `MTIME_LO_ADDR, target[31:0],  2, OK);

      wait_mtime_idle(busy_wait);
      repeat(`LF_CYCLES(6)) @(posedge free_clk);
      read_mtime(before_rst);
      $display("INFO:  MTIME before the warm reset = 0x%h_%h %t ns",
               before_rst[63:32], before_rst[31:0], $time);

      // hresetn_i alone. resetn_lf_i stays high and clk_lf_i keeps running --
      // the always-on domain is exactly what must survive this.
      watching = 1'b1;
      @(posedge free_clk);
      hresetn = 1'b0;
      repeat(`LF_CYCLES(4)) @(posedge free_clk);
      @(posedge free_clk);
      hresetn = 1'b1;
      repeat(`LF_CYCLES(6)) @(posedge free_clk);
      watching = 1'b0;

      read_mtime(rb);
      $display("INFO:  MTIME after  the warm reset = 0x%h_%h %t ns",
               rb[63:32], rb[31:0], $time);

      if (phantom_ld != 0) begin
         $display("ERROR: warm reset of hresetn injected %0d phantom MTIME load(s) %t ns",
                  phantom_ld, $time);
         error = error + 1;
      end

      if (LF_SYNC_EN != 0) begin
         // Synchronous mode: the counter shares hresetn, so it must have
         // restarted near zero rather than carried on from before_rst.
         if (rb >= before_rst) begin
            $display("ERROR: LF_SYNC_EN=1 but MTIME survived a warm reset -- 0x%h_%h then 0x%h_%h; the counter is not sharing hresetn %t ns",
                     before_rst[63:32], before_rst[31:0], rb[63:32], rb[31:0], $time);
            error = error + 1;
         end else if (rb > 64'd10000) begin
            $display("ERROR: LF_SYNC_EN=1: MTIME did not restart near zero after a warm reset -- 0x%h_%h %t ns",
                     rb[63:32], rb[31:0], $time);
            error = error + 1;
         end else begin
            $display("PASS:  LF_SYNC_EN=1: MTIME restarted from the warm reset as expected (0x%h) %t ns", rb[31:0], $time);
         end
      end else if (rb < before_rst) begin
         $display("ERROR: MTIME went BACKWARDS across a warm reset of the AHB domain -- 0x%h_%h then 0x%h_%h %t ns",
                  before_rst[63:32], before_rst[31:0], rb[63:32], rb[31:0], $time);
         error = error + 1;
      end else if ((rb - before_rst) > 64'd10000) begin
         $display("ERROR: MTIME jumped across a warm reset of the AHB domain -- 0x%h_%h then 0x%h_%h %t ns",
                  before_rst[63:32], before_rst[31:0], rb[63:32], rb[31:0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIME survived a warm reset of the AHB domain (drift = %0d LF ticks) %t ns",
                  (rb - before_rst), $time);
      end

      $display("");
      $display(" ===============================================");
      $display("|   WARM RESET : MTIMECMP IS DISARMED           |");
      $display(" ===============================================");

      // The counterpart to the check above, and deliberately the OPPOSITE
      // expectation. MTIME must survive hresetn_i; MTIMECMP must not.
      //
      // The LF-resident MTIMECMP copy is the CDC receiving register and nothing
      // more -- its enable is unconditional, so the reset value that lands in
      // stage 2 is copied down on the next clk_lf_i edge. ACLINT 1.0 Section 2.3
      // leaves the reset value unspecified, and a warm reset of the AHB domain
      // also resets the hart that programmed the deadline, so disarming is the
      // coherent choice. Pinned here so it is a decision rather than an accident:
      // anyone adding reset isolation to that copy has to come through this test.
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, 32'h0000ABCD, 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'h12345678, 2, OK);
      repeat(`LF_CYCLES(6)) @(posedge free_clk);

      if (tb_ahb_aclint.dut.u_mtimer.mtimecmp_cmp[63:0] !== 64'h0000ABCD_12345678) begin
         $display("ERROR: deadline never reached the LF comparator -- 0x%h; the rest of this check is meaningless %t ns",
                  tb_ahb_aclint.dut.u_mtimer.mtimecmp_cmp[63:0], $time);
         error = error + 1;
      end

      @(posedge free_clk);
      hresetn = 1'b0;
      repeat(`LF_CYCLES(4)) @(posedge free_clk);
      @(posedge free_clk);
      hresetn = 1'b1;
      repeat(`LF_CYCLES(6)) @(posedge free_clk);

      ahb_read(1, MACHINE, `MTIMECMP_LO_ADDR, 32'hFFFFFFFF, 2, 0, OK);
      ahb_read(1, MACHINE, `MTIMECMP_HI_ADDR, 32'hFFFFFFFF, 2, 0, OK);
      cmp_rb = tb_ahb_aclint.dut.u_mtimer.mtimecmp_cmp[63:0];

      if (cmp_rb !== 64'hFFFFFFFF_FFFFFFFF) begin
         $display("ERROR: MTIMECMP not disarmed by a warm reset -- LF copy holds 0x%h, expected all-ones %t ns",
                  cmp_rb, $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIMECMP disarmed by the warm reset, in the LF copy too %t ns", $time);
      end

      if (tb_ahb_aclint.irq_m_timer[0] !== 1'b0) begin
         $display("ERROR: MTIP asserted after the warm reset disarmed MTIMECMP %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  no MTIP after the warm reset %t ns", $time);
      end

      $display("");
      $display(" ===============================================");
      $display("|   WARM RESET : hresetn ALONE, SHORTER THAN    |");
      $display("|                ONE clk_lf PERIOD              |");
      $display(" ===============================================");

      // A reset too short for the LF domain to observe. The dangerous outcome
      // is not a wrong value but a load left mid-flight: a request that never
      // retires holds hclk_en_o high for good and blocks deep sleep.
      ahb_write(1, MACHINE, `MTIME_LO_ADDR, 32'h30000000, 2, OK);
      wait_mtime_idle(busy_wait);

      phantom_ld = 0;
      watching   = 1'b1;
      @(posedge free_clk);
      hresetn = 1'b0;
      repeat(2) @(posedge free_clk);
      @(posedge free_clk);
      hresetn = 1'b1;
      repeat(`LF_CYCLES(8)) @(posedge free_clk);
      watching = 1'b0;

      wait_mtime_idle(busy_wait);
      if (busy_wait >= `LF_CYCLES(40)) begin
         $display("ERROR: MTIME write still pending after a short hresetn pulse -- the write path is wedged %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  write path idle after a short hresetn pulse %t ns", $time);
      end

      if (phantom_ld != 0) begin
         $display("ERROR: short hresetn pulse injected %0d phantom MTIME load(s) %t ns",
                  phantom_ld, $time);
         error = error + 1;
      end

      // The channel must still work afterwards. This is the check that a lost
      // transition -- request parity flipped with no LF-side edge -- cannot
      // hide: the next write would never reach the counter.
      target = 64'h00000077_40000000;
      ahb_write(1, MACHINE, `MTIME_HI_ADDR, target[63:32], 2, OK);
      ahb_write(1, MACHINE, `MTIME_LO_ADDR, target[31:0],  2, OK);
      wait_mtime_idle(busy_wait);
      repeat(`LF_CYCLES(6)) @(posedge free_clk);
      read_mtime(rb);

      if ((rb < target) || ((rb - target) > 64'd10000)) begin
         $display("ERROR: MTIME write did not take effect after a short hresetn pulse -- wrote 0x%h_%h read 0x%h_%h %t ns",
                  target[63:32], target[31:0], rb[63:32], rb[31:0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIME write channel still functional after a short hresetn pulse %t ns", $time);
      end

      $display("");
      $display(" ===============================================");
      $display("|   WARM RESET : resetn_lf ALONE (MIRROR)       |");
      $display(" ===============================================");

      if (LF_SYNC_EN != 0) begin
         $display("SKIP:  LF_SYNC_EN=1 -- resetn_lf is tied off, there is no LF-only reset to apply %t ns", $time);
      end else begin

      // The mirror case. MTIME legitimately returns to zero here -- the counter
      // lives in the LF domain and this is its reset. What must NOT happen is a
      // write left pending, or the write channel dying.
      @(posedge free_clk);
      resetn_lf = 1'b0;
      repeat(`LF_CYCLES(2)) @(posedge free_clk);

      // A MTIME write issued while the LF domain alone is in reset is accepted on
      // the bus, forwarded to reads for as long as the request is outstanding, and
      // then DISCARDED: the load is open-loop -- raised on one tick and dropped on
      // the next whether or not the LF side took it -- and the LF side is held in
      // reset, so nothing ever takes it. Ticks do not pause, because the tick
      // generator has no resetn_lf_i. Firmware zeroing MTIME in this window would
      // believe it had succeeded. Holding the request until an ack would
      // reintroduce the handshake this design deliberately does not have, so the
      // behaviour is the contract and this pins it.
      target = 64'h00000077_00000000;
      ahb_write(1, MACHINE, `MTIME_LO_ADDR, target[31:0],  2, OK);
      ahb_write(1, MACHINE, `MTIME_HI_ADDR, target[63:32], 2, OK);

      read_mtime(rb);
      if (rb === target) begin
         $display("PASS:  MTIME write is forwarded to reads while the LF domain is in reset %t ns", $time);
      end else begin
         $display("INFO:  post-write read returned 0x%h_%h, not the written 0x%h_%h -- forwarding window already closed %t ns",
                  rb[63:32], rb[31:0], target[63:32], target[31:0], $time);
      end

      // Outlive the forwarding window, still inside the LF reset.
      repeat(`LF_CYCLES(4)) @(posedge free_clk);
      read_mtime(rb);
      if (rb !== 64'd0) begin
         $display("ERROR: MTIME read 0x%h_%h after the forwarding window -- expected the mirror, which is held at 0 %t ns",
                  rb[63:32], rb[31:0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  the write was discarded -- MTIME reverts to the held-at-zero mirror %t ns", $time);
      end

      @(posedge free_clk);
      resetn_lf = 1'b1;
      repeat(`LF_CYCLES(8)) @(posedge free_clk);

      // ... and it stays discarded once the LF domain is back: MTIME counts up
      // from zero, it does not resume from the value that was written.
      read_mtime(rb);
      if (rb >= target) begin
         $display("ERROR: MTIME came back holding the write issued during LF reset (0x%h_%h) %t ns",
                  rb[63:32], rb[31:0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIME restarted from zero, not from the discarded write %t ns", $time);
      end

      wait_mtime_idle(busy_wait);
      if (busy_wait >= `LF_CYCLES(40)) begin
         $display("ERROR: MTIME write still pending after an LF-only reset -- the write path is wedged %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  write path idle after an LF-only reset %t ns", $time);
      end

      target = 64'h00000099_50000000;
      ahb_write(1, MACHINE, `MTIME_HI_ADDR, target[63:32], 2, OK);
      ahb_write(1, MACHINE, `MTIME_LO_ADDR, target[31:0],  2, OK);
      wait_mtime_idle(busy_wait);
      repeat(`LF_CYCLES(6)) @(posedge free_clk);
      read_mtime(rb);

      if ((rb < target) || ((rb - target) > 64'd10000)) begin
         $display("ERROR: MTIME write did not take effect after an LF-only reset -- wrote 0x%h_%h read 0x%h_%h %t ns",
                  target[63:32], target[31:0], rb[63:32], rb[31:0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIME write channel still functional after an LF-only reset %t ns", $time);
      end

      end

      $display("");
      $display(" ===============================================");
      $display("|   WARM RESET : hresetn WHILE A LOAD IS        |");
      $display("|                IN FLIGHT                      |");
      $display(" ===============================================");

      // The reset-domain crossing itself. The load request, value and write
      // enables are hclk_aon flops read directly by the LF domain; every phase
      // above resets with the write path idle. Here hresetn_i asserts AFTER the
      // load has been launched (load_req high) and BEFORE the clk_lf edge that
      // consumes it. The documented outcome: the write is either applied in
      // full or dropped in full -- the reset clears the request before the LF
      // edge, and the only writer (the hart) is being reset too, so a dropped
      // write is invisible to software. What must never happen is MTIME landing
      // somewhere else: a torn value would survive the reset. Asynchronous mode
      // only: in synchronous mode the counter legitimately restarts.
      if (LF_SYNC_EN != 0) begin
         $display("SKIP:  LF_SYNC_EN=1 -- MTIME restarts on a warm reset by design %t ns", $time);
      end else begin

      read_mtime(before_rst);
      target = 64'h00000123_45670000;
      ahb_write(1, MACHINE, `MTIME_HI_ADDR, target[63:32], 2, OK);
      ahb_write(1, MACHINE, `MTIME_LO_ADDR, target[31:0],  2, OK);

      // Wait for the launch, then land the reset a few hclk later: still well
      // before the next clk_lf edge (LF period >= 8 hclk in every sweep config).
      busy_wait = 0;
      while ((tb_ahb_aclint.dut.u_mtimer.load_req !== 1'b1) && (busy_wait < `LF_CYCLES(10))) begin
         @(posedge free_clk);
         busy_wait = busy_wait + 1;
      end
      if (tb_ahb_aclint.dut.u_mtimer.load_req !== 1'b1) begin
         $display("ERROR: MTIME load never launched; the rest of this check is meaningless %t ns", $time);
         error = error + 1;
      end
      repeat(2) @(posedge free_clk);
      hresetn = 1'b0;
      repeat(3) @(posedge free_clk);
      hresetn = 1'b1;
      repeat(`LF_CYCLES(8)) @(posedge free_clk);

      wait_mtime_idle(busy_wait);
      read_mtime(rb);
      if ((rb >= target) && ((rb - target) <= 64'd10000)) begin
         $display("PASS:  MTIME write in flight at a warm reset of the AHB domain was applied in full (0x%h_%h) %t ns",
                  rb[63:32], rb[31:0], $time);
      end else if ((rb >= before_rst) && ((rb - before_rst) <= 64'd10000)) begin
         $display("PASS:  MTIME write in flight at a warm reset of the AHB domain was dropped in full; the count continued (0x%h_%h) %t ns",
                  rb[63:32], rb[31:0], $time);
      end else begin
         $display("ERROR: MTIME neither holds the written value nor the continued count after a warm reset during a load -- wrote 0x%h_%h, was 0x%h_%h, read 0x%h_%h %t ns",
                  target[63:32], target[31:0], before_rst[63:32], before_rst[31:0], rb[63:32], rb[31:0], $time);
         error = error + 1;
      end

      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
