//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_tick_stress
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_tick_stress.v
// Module Description : EVERY EMITTED TICK MUST BE VALID, UNDER ABUSE.
//
//                      The tick is the single assumption the whole MTIMER rests
//                      on. Consumers capture 64-bit LF state on it and hand data
//                      TO the LF domain on it, and both are safe only because a
//                      tick means "a bounded time has passed since a clk_lf_i
//                      rising edge, so everything on that side has settled".
//
//                      A tick that does not carry that meaning is far worse than
//                      a missing one: it captures MTIME mid-increment (a TORN
//                      value, not a stale one) or moves a write shadow while the
//                      LF side is sampling it. Nothing downstream can detect
//                      either.
//
//                      The dangerous case is resumption. Every hclk_aon_i flop
//                      freezes at its pre-sleep value while the oscillator is
//                      stopped, so for the first edges afterwards the observer
//                      pipeline holds a MIX of pre-sleep and fresh samples and
//                      its edge detector can fire on the comparison between
//                      them -- a tick with no relationship to any clk_lf_i edge
//                      at all. This test hammers that boundary.
//
//                      INVARIANTS, checked continuously rather than at sync
//                      points, so a single bad tick anywhere fails the run:
//
//                        I1  Every tick is preceded by a clk_lf_i rising edge it
//                            can be attributed to -- at most ONE tick per edge.
//                        I2  A tick lands at least 2 hclk_aon_i edges after that
//                            clk_lf_i edge (the settling guarantee), and within
//                            the same LF period (so it is attributable at all).
//                        I3  MTIME never runs backwards and never advances
//                            faster than clk_lf_i itself.
//
//                      Missing ticks are legal and expected: they are exactly
//                      what suppression does while the observer is unproven.
//                      This test asserts nothing about tick COUNT, only that an
//                      emitted tick is always meaningful.
//----------------------------------------------------------------------------

integer    ii;
integer    aon_since_edge;      // hclk_aon_i edges since the last clk_lf_i rising edge
integer    ticks_this_edge;     // ticks attributed to the current clk_lf_i edge
integer    tick_total;
integer    lf_edge_total;
integer    sleeps;
integer    guard;
integer    asleep_ns;
integer    sleep_ticks;
integer    i1_fail;
integer    i2_fail;
integer    phase;
reg        armed;
reg [63:0] mt_prev;
reg [63:0] mt_now;

// Attribution window. A tick must be at least 2 hclk_aon_i edges after the LF
// edge (2-FF sync plus the compare) and must not outlive the LF period it
// belongs to.
`define TICK_MIN_AON 2
`define TICK_MAX_AON `LF_RATIO

//----------------------------------------------------------------------------
// I1 / I2 -- continuous tick monitor
//----------------------------------------------------------------------------
initial
   begin
      aon_since_edge  = 0;
      ticks_this_edge = 0;
      tick_total      = 0;
      lf_edge_total   = 0;
      i1_fail         = 0;
      i2_fail         = 0;
      armed           = 1'b0;
   end

// A clk_lf_i rising edge opens a fresh attribution window.
always @(posedge clk_lf) begin
   aon_since_edge  = 0;
   ticks_this_edge = 0;
   if (armed) lf_edge_total = lf_edge_total + 1;
end

// Count hclk_aon_i edges, and vet every tick. Counting on hclk_aon_i rather than
// free_clk is deliberate: it stops advancing exactly when the oscillator does,
// so a tick emitted right after resumption is measured against the LF edge it
// actually claims, not against wall-clock time that elapsed while stopped.
always @(posedge tb_ahb_aclint.hclk_aon) begin
   aon_since_edge = aon_since_edge + 1;

   if (tb_ahb_aclint.dut.u_mtimer.lf_tick === 1'b1) begin
      if (armed) begin
         tick_total = tick_total + 1;

         // I1: one tick per LF edge, never two.
         if (ticks_this_edge != 0) begin
            i1_fail = i1_fail + 1;
            $display("ERROR: I1 -- second tick attributed to one clk_lf edge (tick %0d) %t ns",
                     tick_total, $time);
         end

         // I2: inside the settling window, and attributable to THIS LF period.
         if (aon_since_edge < `TICK_MIN_AON) begin
            i2_fail = i2_fail + 1;
            $display("ERROR: I2 -- tick only %0d hclk_aon edges after the clk_lf edge (min %0d); LF state may not have settled %t ns",
                     aon_since_edge, `TICK_MIN_AON, $time);
         end
         if (aon_since_edge > `TICK_MAX_AON) begin
            i2_fail = i2_fail + 1;
            $display("ERROR: I2 -- tick %0d hclk_aon edges after the last clk_lf edge (max %0d); not attributable to it %t ns",
                     aon_since_edge, `TICK_MAX_AON, $time);
         end
      end
      ticks_this_edge = ticks_this_edge + 1;
   end
end

//----------------------------------------------------------------------------
// Stimulus
//----------------------------------------------------------------------------
initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);

      if (LF_SYNC_EN != 0) begin
         tb_skip_finish("mtimer_tick_stress sleeps the oscillator; needs an LF-resident timebase (LF_SYNC_EN=0)");
      end

      repeat(`LF_CYCLES(4)) @(posedge free_clk);

      $display(" ===============================================");
      $display("|   LF TICK : VALIDITY UNDER ABUSE              |");
      $display(" ===============================================");

      // Park MTIMECMP so MTIP cannot fire and perturb the clock enables.
      ahb_write(1, MACHINE, 32'h00404000, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, 32'h00404004, 32'hFFFFFFFF, 2, OK);
      repeat(`LF_CYCLES(4)) @(posedge free_clk);

      armed   = 1'b1;
      sleeps  = 0;
      mt_prev = tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_lf;

      // Rounds of legal sleeps. The oscillator can only be stopped by letting
      // the IP go quiet -- hclk_aon_en at chip level is the OR of every block's
      // clock request, so there is no way to take the clock away from a block
      // that is still asking for it. An earlier version of this test forced the
      // clock off regardless, which exercised interruptions the hardware cannot
      // produce; the durations below are instead whatever a real deadline gives.
      for (ii = 0; ii < 12; ii = ii + 1) begin

         // --- distort the duty cycle, including down to the documented floor
         case (ii % 4)
           0: lf_high_period = `ACLINT_LF_HALF_PERIOD;                 // symmetric
           1: lf_high_period = 50;                                     // ~2 hclk high
           2: lf_high_period = (2 * `ACLINT_LF_HALF_PERIOD) - 50;      // ~2 hclk low
           3: lf_high_period = `ACLINT_LF_HALF_PERIOD / 2;             // 25% duty
         endcase
         repeat(`LF_CYCLES(2)) @(posedge free_clk);

         // --- sleep, with the wake deadline setting the duration. Short sleeps
         //     do not span an LF edge; long ones leave the observer thoroughly
         //     stale on resumption. Both are legal and both must produce only
         //     valid ticks.
         mt_now = tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_lf;
         case (ii % 4)
           0: sleep_ticks = 2;
           1: sleep_ticks = 5;
           2: sleep_ticks = 17;
           3: sleep_ticks = 33;
         endcase
         ahb_write(1, MACHINE, 32'h00404004, mt_now[63:32],                        2, OK);
         ahb_write(1, MACHINE, 32'h00404000, mt_now[31:0] + sleep_ticks,           2, OK);
         repeat(`LF_CYCLES(3)) @(posedge free_clk);

         allow_deep_sleep = 1'b1;
         guard = 0;
         while ((tb_ahb_aclint.hclk_en === 1'b1) && (guard < `LF_CYCLES(10))) begin
            @(posedge free_clk);
            guard = guard + 1;
         end

         // No clock from here until the wake: # delays only.
         if (tb_ahb_aclint.hclk_en === 1'b0) sleeps = sleeps + 1;
         asleep_ns = 0;
         while ((tb_ahb_aclint.mtimer_wake_lf === 1'b0) &&
                (asleep_ns < 200*`ACLINT_LF_HALF_PERIOD)) begin
            #100;
            asleep_ns = asleep_ns + 100;
         end
         allow_deep_sleep = 1'b0;
         #500;

         // Disarm so the next round starts clean.
         repeat(`LF_CYCLES(2)) @(posedge free_clk);
         ahb_write(1, MACHINE, 32'h00404000, 32'hFFFFFFFF, 2, OK);
         ahb_write(1, MACHINE, 32'h00404004, 32'hFFFFFFFF, 2, OK);
         repeat(`LF_CYCLES(2)) @(posedge free_clk);

         // --- I3: MTIME must never run backwards.
         mt_now = tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_lf;
         if (mt_now < mt_prev) begin
            $display("ERROR: I3 -- MTIME ran BACKWARDS across round %0d: 0x%h -> 0x%h %t ns",
                     ii, mt_prev, mt_now, $time);
            error = error + 1;
         end
         mt_prev = mt_now;
      end

      lf_high_period = `ACLINT_LF_HALF_PERIOD;
      repeat(`LF_CYCLES(6)) @(posedge free_clk);

      //----------------------------------------------------------------------
      // PHASE SWEEP -- stop the clock INSIDE the sampling pipeline
      //----------------------------------------------------------------------
      // The rounds above always resume from a wake, which lands the stop at
      // roughly one fixed phase relative to clk_lf. That never places the stop
      // in the window that actually matters: the 2-3 hclk edges during which a
      // clk_lf rising edge is still IN FLIGHT through the synchronizer, so the
      // frozen pipeline holds a half-propagated edge. Resuming from there, the
      // edge detector compares a stale operand against a fresh one and can emit
      // a tick with no defined relationship to any clk_lf edge.
      //
      // Sweeping the stop point 0..3 edges past a clk_lf rising edge covers
      // that window deterministically. This is what makes the test sensitive to
      // the warm-up depth: with the counter shortened, a tick escapes here and
      // I2 catches it.
      $display("");
      $display(" ===============================================");
      $display("|   PHASE SWEEP : STOP INSIDE THE PIPELINE      |");
      $display(" ===============================================");

      for (phase = 0; phase < 4; phase = phase + 1) begin
         // Arm far enough out that the block is fully quiesced before we stop.
         mt_now = tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_lf;
         ahb_write(1, MACHINE, 32'h00404004, mt_now[63:32],            2, OK);
         ahb_write(1, MACHINE, 32'h00404000, mt_now[31:0] + 32'd6,     2, OK);

         guard = 0;
         while ((tb_ahb_aclint.hclk_en === 1'b1) && (guard < `LF_CYCLES(10))) begin
            @(posedge free_clk);
            guard = guard + 1;
         end

         // Align to a clk_lf rising edge, step `phase` hclk_aon edges into the
         // synchronizer, then let the oscillator go.
         @(posedge clk_lf);
         repeat(phase) @(posedge tb_ahb_aclint.hclk_aon);
         allow_deep_sleep = 1'b1;

         asleep_ns = 0;
         while ((tb_ahb_aclint.mtimer_wake_lf === 1'b0) &&
                (asleep_ns < 200*`ACLINT_LF_HALF_PERIOD)) begin
            #100;
            asleep_ns = asleep_ns + 100;
         end
         allow_deep_sleep = 1'b0;
         #500;

         repeat(`LF_CYCLES(3)) @(posedge free_clk);
         ahb_write(1, MACHINE, 32'h00404000, 32'hFFFFFFFF, 2, OK);
         ahb_write(1, MACHINE, 32'h00404004, 32'hFFFFFFFF, 2, OK);
         repeat(`LF_CYCLES(3)) @(posedge free_clk);
         $display("INFO:  stopped %0d hclk_aon edge(s) after a clk_lf edge -- %0d I2 failures so far %t ns",
                  phase, i2_fail, $time);
      end

      repeat(`LF_CYCLES(4)) @(posedge free_clk);
      armed = 1'b0;

      $display("INFO:  %0d sleeps, %0d clk_lf edges, %0d ticks emitted %t ns",
               sleeps, lf_edge_total, tick_total, $time);

      //----------------------------------------------------------------------
      // Verdicts
      //----------------------------------------------------------------------
      if (i1_fail != 0) begin
         $display("ERROR: I1 violated %0d time(s) -- a tick was emitted with no clk_lf edge to attribute it to %t ns",
                  i1_fail, $time);
         error = error + 1;
      end else begin
         $display("PASS:  I1 -- at most one tick per clk_lf edge, always %t ns", $time);
      end

      if (i2_fail != 0) begin
         $display("ERROR: I2 violated %0d time(s) -- a tick landed outside the settling window %t ns",
                  i2_fail, $time);
         error = error + 1;
      end else begin
         $display("PASS:  I2 -- every tick inside [%0d, %0d] hclk_aon edges of its clk_lf edge %t ns",
                  `TICK_MIN_AON, `TICK_MAX_AON, $time);
      end

      // I3, second half: ticks can be suppressed but never invented, so the
      // count can never exceed the number of clk_lf edges that occurred.
      if (tick_total > lf_edge_total) begin
         $display("ERROR: I3 -- %0d ticks for only %0d clk_lf edges; the timebase would run FAST %t ns",
                  tick_total, lf_edge_total, $time);
         error = error + 1;
      end else begin
         $display("PASS:  I3 -- %0d ticks <= %0d clk_lf edges (suppression is safe, invention is not) %t ns",
                  tick_total, lf_edge_total, $time);
      end

      // A run that emitted almost nothing would satisfy every invariant above
      // while proving nothing, so require the stimulus to have actually ticked.
      if (tick_total < (lf_edge_total / 4)) begin
         $display("ERROR: only %0d ticks for %0d clk_lf edges -- suppression is too aggressive to have tested anything %t ns",
                  tick_total, lf_edge_total, $time);
         error = error + 1;
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
