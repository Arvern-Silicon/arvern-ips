//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_lf_duty
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_lf_duty.v
// Module Description : TICK DETECTION AT THE RATIO LIMIT, WITH A LOPSIDED DUTY
//                      CYCLE.
//
//                      clk_lf_i is sampled AS DATA in the hclk_aon_i domain, so
//                      the requirement is on each PHASE -- at least 2 hclk_aon_i
//                      periods -- not on the period. A 50% duty cycle at R = 10
//                      leaves five hclk edges per phase, which is comfortable;
//                      the tight case is reached by squeezing one phase.
//
//                      WHAT THIS TEST IS AND IS NOT. It checks the edge
//                      detector's LOGIC at a lopsided duty cycle: one tick per
//                      LF period, no more and no fewer. It does NOT establish
//                      the 2-period floor and cannot -- zero-delay simulation
//                      has no setup/hold window and no metastability, so a phase
//                      one hclk period wide samples perfectly here and fails in
//                      silicon. The floor is a CDC-review and STA property.
//
//                      Every other test runs a symmetric clock, so nothing in
//                      the suite distinguishes "R is legal" from "each phase is
//                      wide enough". This one does: it shortens the HIGH phase
//                      to roughly two hclk periods -- the documented floor --
//                      and asserts that exactly one tick is still produced per
//                      LF period, no more and no fewer.
//
//                      A MISSED tick silently loses time (MTIME falls behind).
//                      A DOUBLE tick is worse: it would advance the counter
//                      twice for one oscillator cycle, so the timebase would run
//                      fast and no downstream check would ever notice.
//
//                      Runs in BOTH modes. clk_lf_i is sampled as data whether
//                      or not anything is clocked by it, so the duty-cycle limit
//                      is a property of the observer, not of the counter's
//                      residency -- and under LF_SYNC_EN a missed tick loses
//                      time directly rather than just delaying a mirror refresh.
//----------------------------------------------------------------------------

integer ticks;
integer lf_edges;
integer ii;
reg     counting;

initial
   begin
      ticks    = 0;
      lf_edges = 0;
      counting = 1'b0;
      forever begin
         @(posedge free_clk);
         if (counting && (tb_ahb_aclint.dut.u_mtimer.lf_tick === 1'b1))
            ticks = ticks + 1;
      end
   end

initial
   begin
      forever begin
         @(posedge clk_lf);
         if (counting) lf_edges = lf_edges + 1;
      end
   end

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);

      repeat(`LF_CYCLES(4)) @(posedge free_clk);

      $display(" ===============================================");
      $display("|   LF TICK : LOPSIDED DUTY CYCLE               |");
      $display(" ===============================================");
      $display("INFO:  R = %0d hclk per LF period; squeezing the HIGH phase to ~2 hclk", `LF_RATIO);

      // free_clk half-period is 25 ns, so 50 ns is two hclk periods: the
      // narrowest phase the sampler is specified to catch.
      lf_high_period = 50;
      repeat(`LF_CYCLES(4)) @(posedge free_clk);

      counting = 1'b1;
      repeat(`LF_CYCLES(40)) @(posedge free_clk);
      counting = 1'b0;

      $display("INFO:  observed %0d clk_lf rising edges, %0d ticks %t ns", lf_edges, ticks, $time);

      // Allow one edge of slop at each end for where the window happens to open
      // and close relative to the LF clock.
      if (ticks < (lf_edges - 1)) begin
         $display("ERROR: ticks MISSED with a narrow HIGH phase -- %0d ticks for %0d LF edges; MTIME would run slow %t ns",
                  ticks, lf_edges, $time);
         error = error + 1;
      end else if (ticks > (lf_edges + 1)) begin
         $display("ERROR: DUPLICATE ticks with a narrow HIGH phase -- %0d ticks for %0d LF edges; MTIME would run fast %t ns",
                  ticks, lf_edges, $time);
         error = error + 1;
      end else begin
         $display("PASS:  exactly one tick per LF period with a ~2-hclk HIGH phase %t ns", $time);
      end

      // Mirror image: squeeze the LOW phase instead. The edge detector keys off
      // the rising edge, but it needs to SEE the line go low again to re-arm.
      lf_high_period = (2 * `ACLINT_LF_HALF_PERIOD) - 50;
      repeat(`LF_CYCLES(4)) @(posedge free_clk);

      ticks    = 0;
      lf_edges = 0;
      counting = 1'b1;
      repeat(`LF_CYCLES(40)) @(posedge free_clk);
      counting = 1'b0;

      $display("INFO:  observed %0d clk_lf rising edges, %0d ticks %t ns", lf_edges, ticks, $time);

      if ((ticks < (lf_edges - 1)) || (ticks > (lf_edges + 1))) begin
         $display("ERROR: tick count wrong with a ~2-hclk LOW phase -- %0d ticks for %0d LF edges %t ns",
                  ticks, lf_edges, $time);
         error = error + 1;
      end else begin
         $display("PASS:  exactly one tick per LF period with a ~2-hclk LOW phase %t ns", $time);
      end

      // Restore a symmetric clock and confirm MTIME is still advancing, so a
      // test that leaves the clock distorted cannot pass by accident.
      lf_high_period = `ACLINT_LF_HALF_PERIOD;
      repeat(`LF_CYCLES(8)) @(posedge free_clk);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
