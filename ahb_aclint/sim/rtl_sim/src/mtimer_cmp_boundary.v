//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_cmp_boundary
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_cmp_boundary
// Module Description : Exact-tick MTIMECMP comparator boundary check. The
//                      existing wake tests only confirm "MTIP fires within N
//                      cycles" (multi-thousand-cycle tolerance), so a one-LF-
//                      tick shift (e.g. mtime_bin_next->mtime_bin_now, or
//                      >=->>) would pass. The spec requires MTIP pending
//                      exactly when mtime >= mtimecmp; with the +1 register
//                      offset (aclint_mtimer_count_lf.v:87) the per-hart flop
//                      irq_m_timer_lf_r[h] must rise on the precise LF edge
//                      where mtime_bin_now first EQUALS the programmed
//                      mtimecmp. This watches the LF counter cross a known
//                      absolute target and asserts the rising edge lands on
//                      exactly that count (and not one tick early/late).
//----------------------------------------------------------------------------

reg  [63:0] mt_target;
reg  [63:0] mt_at_edge;
reg  [63:0] mt_prev;
reg         prev_irq;
reg         cur_irq;
reg         boundary_done;
integer     guard;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(20) @(posedge free_clk);

      $display(" ===============================================");
      $display("|     MTIMER : COMPARATOR EXACT-TICK BOUNDARY   |");
      $display(" ===============================================");

      // Pick an absolute LF target a comfortable margin ahead of the current
      // LF count, so the write CDC lands well before mtime reaches it.
      @(negedge clk_lf);
      mt_target = tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_bin_now + 64'd60;
      $display("INFO:  current mtime=0x%h  target mtimecmp=0x%h %t ns",
               tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_bin_now, mt_target, $time);

      ahb_write(1, MACHINE, 32'h00404000, mt_target[31:0],  2, OK);
      ahb_write(1, MACHINE, 32'h00404004, mt_target[63:32], 2, OK);

      // Let the write CDC commit the new compare value on the LF side.
      repeat(40) @(posedge free_clk);

      // Watch the LF comparator flop. Capture mtime on the exact edge MTIP rises.
      prev_irq      = tb_ahb_aclint.dut.u_mtimer.u_count_lf.irq_m_timer_lf_r[0];
      mt_prev       = tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_bin_now;
      boundary_done = 1'b0;
      guard         = 0;
      while (!boundary_done && (guard < 4000)) begin
         @(negedge clk_lf);
         guard      = guard + 1;
         cur_irq    = tb_ahb_aclint.dut.u_mtimer.u_count_lf.irq_m_timer_lf_r[0];
         mt_at_edge = tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_bin_now;

         if (cur_irq && !prev_irq) begin
            // Rising edge of the per-hart comparator flop.
            if (mt_at_edge == mt_target) begin
               $display("PASS:  MTIP rose at mtime==mtimecmp (0x%h) -- exact boundary, prev tick mtime=0x%h irq=0 %t ns",
                        mt_at_edge, mt_prev, $time);
            end else begin
               $display("ERROR: MTIP rose at mtime=0x%h but mtimecmp=0x%h (off by %0d LF ticks) %t ns",
                        mt_at_edge, mt_target, ($signed(mt_at_edge - mt_target)), $time);
               error = error + 1;
            end
            // The tick immediately before the edge must NOT have been asserted.
            if (prev_irq !== 1'b0) begin
               $display("ERROR: MTIP was already high one tick before the boundary %t ns", $time);
               error = error + 1;
            end
            boundary_done = 1'b1;
         end
         prev_irq = cur_irq;
         mt_prev  = mt_at_edge;
      end

      if (!boundary_done) begin
         $display("ERROR: MTIP never crossed the programmed boundary within the guard window %t ns", $time);
         error = error + 1;
      end

      // Cleanup.
      ahb_write(1, MACHINE, 32'h00404000, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, 32'h00404004, 32'hFFFFFFFF, 2, OK);
      repeat(40) @(posedge free_clk);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
