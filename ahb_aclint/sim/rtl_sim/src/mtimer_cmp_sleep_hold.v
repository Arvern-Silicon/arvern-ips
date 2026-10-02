//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_cmp_sleep_hold
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_cmp_sleep_hold
// Module Description : `sw mtimecmp; wfi` -- ARM AND SLEEP IMMEDIATELY.
//
//                      mtimer_deep_sleep deliberately lets the deadline settle
//                      before quiescing, so it measures the sleep itself. This
//                      test removes that settle time, which is the sequence real
//                      tickless-idle firmware actually executes: program the next
//                      deadline, then go to sleep on the very next instruction.
//
//                      A MTIMECMP write reaches stage 2 -- which the LF
//                      comparator reads directly -- only on the next LF tick,
//                      and the comparator sees it on the clk_lf_i edge after
//                      that. Until then it still holds the OLD deadline. If the
//                      block lets its clock request drop in that window, the SoC --
//                      whose hclk_aon_en is the OR of every IP's request -- stops
//                      the oscillator, the crossing never completes, and the wake
//                      that was supposed to end the sleep never fires. Nothing
//                      is left running to correct it.
//
//                      Checked two ways, because the first symptom silences the
//                      instrument: once the oscillator stops there are no more
//                      free_clk edges for a clocked monitor to run on. So there
//                      is an edge-sampled window check AND a wall-clock check on
//                      whether the deadline arrived at all.
//----------------------------------------------------------------------------

reg [63:0] now;
reg [63:0] deadline;
reg        armed;
reg        saw_en_low_early;
integer    guard;
integer    waited_ns;

`define MTIME_LO_ADDR    32'h0040BFF8
`define MTIME_HI_ADDR    32'h0040BFFC
`define MTIMECMP_LO_ADDR 32'h00404000
`define MTIMECMP_HI_ADDR 32'h00404004

// The clock request must not drop while the deadline is still in flight.
// Sampled on free_clk, so it only observes the period the oscillator runs --
// which is exactly the period in which dropping the request is the fault.
initial
   begin
      armed            = 1'b0;
      saw_en_low_early = 1'b0;
      forever begin
         @(posedge free_clk);
         if (armed && (tb_ahb_aclint.hclk_en === 1'b0) &&
             (tb_ahb_aclint.dut.u_mtimer.mtimecmp_cmp[63:0] !== deadline))
            saw_en_low_early = 1'b1;
      end
   end

task read_mtime;
   output [63:0] val;
   begin
      ahb_read(1, MACHINE, `MTIME_LO_ADDR, 32'h00000000, 2, 0, OK);
      ahb_read(1, MACHINE, `MTIME_HI_ADDR, 32'h00000000, 2, 0, OK);
      val = tb_ahb_aclint.mtime_shadow_ahb_sim;
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);

      if (LF_SYNC_EN != 0) begin
         tb_skip_finish("mtimer_cmp_sleep_hold needs an LF-resident timebase (LF_SYNC_EN=0)");
      end

      repeat(`LF_CYCLES(6)) @(posedge free_clk);

      $display(" ===============================================");
      $display("|   ARM AND SLEEP : NO SETTLE TIME              |");
      $display(" ===============================================");

      read_mtime(now);
      deadline = {now[63:32], now[31:0] + 32'd40};
      $display("INFO:  MTIME = 0x%h_%h, arming deadline 0x%h_%h %t ns",
               now[63:32], now[31:0], deadline[63:32], deadline[31:0], $time);

      // Arm, then immediately let go -- no repeat() in between. This is the
      // whole point of the test.
      //
      // `armed` is raised only AFTER the writes, not before: ahb_write returns
      // while the data phase is still in flight, so a monitor armed earlier
      // would sample hclk_en before the write strobe could set cmp_recent and
      // could flag a hold that was never owed.
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, deadline[63:32], 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, deadline[31:0],  2, OK);
      guard = 0;
      while ((tb_ahb_aclint.dut.u_mtimer.wr_pending === 1'b0) &&
             (guard < `LF_CYCLES(2))) begin
         @(posedge free_clk);
         guard = guard + 1;
      end
      if (tb_ahb_aclint.dut.u_mtimer.wr_pending !== 1'b1) begin
         $display("ERROR: the MTIMECMP write never registered as pending %t ns", $time);
         error = error + 1;
      end
      armed            = 1'b1;
      allow_deep_sleep = 1'b1;

      // Wall clock, not edges: if the fault is present the oscillator is already
      // stopped and there is nothing left to count cycles with. Budget well past
      // the two ticks the crossing needs.
      waited_ns = 0;
      while ((tb_ahb_aclint.dut.u_mtimer.mtimecmp_cmp[63:0] !== deadline) &&
             (waited_ns < 20*`ACLINT_LF_HALF_PERIOD)) begin
         #100;
         waited_ns = waited_ns + 100;
      end

      if (tb_ahb_aclint.dut.u_mtimer.mtimecmp_cmp[63:0] !== deadline) begin
         $display("ERROR: deadline never reached the LF comparator -- it holds 0x%h, the clock went away mid-crossing %t ns",
                  tb_ahb_aclint.dut.u_mtimer.mtimecmp_cmp[63:0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  deadline reached the LF comparator after %0d ns %t ns", waited_ns, $time);
      end

      if (saw_en_low_early) begin
         $display("ERROR: hclk_en_o dropped while the MTIMECMP write was still crossing %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  hclk_en_o held throughout the MTIMECMP crossing %t ns", $time);
      end
      armed = 1'b0;

      // Having held the clock, the block must then LET GO -- a hold that never
      // releases prevents deep sleep just as effectively as one that is missing.
      guard = 0;
      while ((tb_ahb_aclint.hclk_en === 1'b1) && (guard < `LF_CYCLES(20))) begin
         @(posedge free_clk);
         guard = guard + 1;
      end
      if (tb_ahb_aclint.hclk_en === 1'b1) begin
         $display("ERROR: hclk_en_o never released after the crossing completed %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  hclk_en_o released %0d cycles after the write %t ns", guard, $time);
      end

      #2000;
      if (tb_ahb_aclint.hclk_aon_en !== 1'b0) begin
         $display("ERROR: oscillator still running with every clock request released %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  oscillator stopped %t ns", $time);
      end

      $display("");
      $display(" ===============================================");
      $display("|   ARM AND SLEEP : THE WAKE STILL ARRIVES      |");
      $display(" ===============================================");

      waited_ns = 0;
      while ((tb_ahb_aclint.mtimer_wake_lf === 1'b0) &&
             (waited_ns < 200*`ACLINT_LF_HALF_PERIOD)) begin
         #100;
         waited_ns = waited_ns + 100;
      end

      if (tb_ahb_aclint.mtimer_wake_lf !== 1'b1) begin
         $display("ERROR: the armed deadline never woke the chip -- slept forever %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  deadline expired and raised the wake (%0d ns asleep) %t ns", waited_ns, $time);
      end

      #500;
      if (tb_ahb_aclint.hclk_aon_en !== 1'b1) begin
         $display("ERROR: wake asserted but the oscillator did not restart %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  wake asynchronously restarted the oscillator %t ns", $time);
      end

      allow_deep_sleep = 1'b0;
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'hFFFFFFFF, 2, OK);
      repeat(`LF_CYCLES(4)) @(posedge free_clk);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
