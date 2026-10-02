//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_deep_sleep
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_deep_sleep.v
// Module Description : OSC-OFF DEEP SLEEP, THROUGH THE ONLY PATH THE CHIP HAS.
//
//                      hclk_aon_en at chip level is the OR of every IP's clock
//                      request, so the oscillator stops only once ALL of them
//                      have let go -- this one included. A test cannot simply
//                      switch the clock off; it has to EARN the sleep by
//                      quiescing the IP. And once the oscillator is off, the
//                      only thing that can restart it is an asynchronous wake,
//                      of which mtimer_wake_lf_o is the source here.
//
//                      That is the entire reason the LF domain exists, and it is
//                      now covered as one sequence:
//
//                        1. arm a deadline, let it reach the LF comparator
//                        2. quiesce; hclk_en_o drops; the oscillator stops
//                        3. MTIME keeps counting with no hclk anywhere
//                        4. the deadline expires; mtimer_wake_lf_o asynchronously
//                           restarts the oscillator
//                        5. the mirror revalidates and MTIME reads correctly
//
//                      TIMING: free_clk IS the oscillator, so while the chip
//                      sleeps there are no edges to wait on. Waits spanning the
//                      sleep use # delays -- not a shortcut, the only honest way
//                      to represent time passing with every clock stopped.
//----------------------------------------------------------------------------

reg [63:0] before_sleep;
reg [63:0] after_wake;
reg [31:0] deadline_lo;
integer    loads;
integer    stall_cycles;
integer    guard;
integer    asleep_ns;
reg        counting;
reg        ack_d;
integer    edge_cnt;
reg        count_edges;
integer    trust_edges;

`define MTIME_LO_ADDR    32'h0040BFF8
`define MTIME_HI_ADDR    32'h0040BFFC
`define MTIMECMP_LO_ADDR 32'h00404000
`define MTIMECMP_HI_ADDR 32'h00404004

// Free-running edge counter, armed by count_edges. Used where the question is
// simply "did the oscillator keep going", which no hclk-domain flop can answer
// about its own clock.
initial
   begin
      edge_cnt    = 0;
      count_edges = 1'b0;
      forever begin
         @(posedge free_clk);
         if (count_edges) edge_cnt = edge_cnt + 1;
      end
   end

// Trust release after a wake: the oscillator restarts with lf_trust_rstn
// still low, and the release must come from the two-stage synchronizer,
// i.e. on exactly the second hclk_aon edge, in EITHER reset style. A release
// that needs no edge means the wake reaches the reset of warm_cnt /
// mirror_valid straight from the asynchronous hclk_aon_en, which is a
// metastability hazard on an aborted sleep.
initial
   begin
      trust_edges = -1;
      @(posedge hresetn);
      @(negedge tb_ahb_aclint.hclk_aon_en);    // first sleep entry
      @(posedge tb_ahb_aclint.hclk_aon_en);    // wake, before the clock restarts
      trust_edges = 0;
      while (tb_ahb_aclint.dut.u_mtimer.lf_trust_rstn !== 1'b1) begin
         @(posedge free_clk);
         #1;
         trust_edges = trust_edges + 1;
      end
   end

// LF-side load strobes. The one-shot contract is one load per software write,
// and it must hold across a sleep that leaves load_req asserted.
initial
   begin
      loads    = 0;
      counting = 1'b0;
      ack_d    = 1'b0;
      forever begin
         @(posedge clk_lf);
         if (counting && (tb_ahb_aclint.dut.u_mtimer.load_ack_lf === 1'b1) && (ack_d === 1'b0))
            loads = loads + 1;
         ack_d = tb_ahb_aclint.dut.u_mtimer.load_ack_lf;
      end
   end

// Wait states on the first post-wake MTIME read.
initial
   begin
      stall_cycles = 0;
      forever begin
         @(posedge free_clk);
         if (tb_ahb_aclint.dut.u_mtimer.mtime_read_stall === 1'b1)
            stall_cycles = stall_cycles + 1;
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
         tb_skip_finish("mtimer_deep_sleep needs an LF-resident timebase (LF_SYNC_EN=0)");
      end

      repeat(`LF_CYCLES(6)) @(posedge free_clk);

      $display(" ===============================================");
      $display("|   DEEP SLEEP : ARM, SLEEP, BE WOKEN BY MTIP   |");
      $display(" ===============================================");

      read_mtime(before_sleep);
      $display("INFO:  MTIME before sleep = 0x%h_%h %t ns",
               before_sleep[63:32], before_sleep[31:0], $time);

      // Arm a deadline a few LF ticks out and let it reach the LF comparator
      // BEFORE quiescing. Arming and sleeping immediately is a different
      // question -- whether hclk_en_o covers the propagation window -- and is
      // deliberately not what this test measures.
      // Far enough out that the oscillator is off for MANY LF periods. A short
      // sleep does not span an LF edge, so the mirror never goes stale and the
      // revalidation path below would not be exercised at all.
      deadline_lo = before_sleep[31:0] + 32'd40;
      counting    = 1'b1;
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, before_sleep[63:32], 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, deadline_lo,         2, OK);
      repeat(`LF_CYCLES(4)) @(posedge free_clk);

      if (tb_ahb_aclint.dut.u_mtimer.mtimecmp_cmp[31:0] !== deadline_lo) begin
         $display("ERROR: deadline never reached the LF comparator -- the sleep below could not wake %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  deadline reached the LF comparator %t ns", $time);
      end

      // Let go. The oscillator stops only when the IP stops asking for it.
      allow_deep_sleep = 1'b1;

      guard = 0;
      while ((tb_ahb_aclint.hclk_en === 1'b1) && (guard < `LF_CYCLES(20))) begin
         @(posedge free_clk);
         guard = guard + 1;
      end
      if (tb_ahb_aclint.hclk_en === 1'b1) begin
         $display("ERROR: hclk_en_o never dropped -- the IP would prevent deep sleep entirely %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  IP released hclk_en_o after %0d cycles %t ns", guard, $time);
      end

      // From here there may be no clock at all: # delays only.
      #2000;
      if (tb_ahb_aclint.hclk_aon_en !== 1'b0) begin
         $display("ERROR: oscillator still running with every clock request released %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  oscillator stopped -- hclk and hclk_aon both gone %t ns", $time);
      end

      // Wait for the LF comparator to fire. No hclk-domain logic can take part.
      asleep_ns = 0;
      // Bound generously: the deadline is 40 LF TICKS out, and one tick is a
      // full LF period (2 * ACLINT_LF_HALF_PERIOD), so the sleep is ~20 us at
      // the default ratio. Budget 100 LF periods.
      while ((tb_ahb_aclint.mtimer_wake_lf === 1'b0) && (asleep_ns < 200*`ACLINT_LF_HALF_PERIOD)) begin
         #100;
         asleep_ns = asleep_ns + 100;
      end

      if (tb_ahb_aclint.mtimer_wake_lf !== 1'b1) begin
         $display("ERROR: deadline expired but mtimer_wake_lf_o never asserted -- the chip cannot wake %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIME expired during the sleep and raised the wake (%0d ns asleep) %t ns",
                  asleep_ns, $time);
      end

      // The wake is an asynchronous preset: the oscillator must restart with no
      // clock edge required from anywhere in the design.
      #500;
      if (tb_ahb_aclint.hclk_aon_en !== 1'b1) begin
         $display("ERROR: wake asserted but the oscillator did not restart %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  wake asynchronously restarted the oscillator %t ns", $time);
      end

      if (trust_edges != 2) begin
         $display("ERROR: trust released %0d hclk_aon edge(s) after the wake (expected 2, through the synchronizer) %t ns",
                  trust_edges, $time);
         error = error + 1;
      end else begin
         $display("PASS:  trust released through the synchronizer, 2 edges after the wake %t ns", $time);
      end

      // No phantom loads across the sleep. Note this is now a weaker check than
      // it looks: the IP holds hclk_en_o while a load is outstanding, so the
      // oscillator cannot stop with one in flight -- that is the liveness
      // guarantee working. The LF-side one-shot remains as belt-and-braces, and
      // mtimer_load_oneshot is what actually proves it (exactly one load per
      // write). What this asserts is narrower and still worth having: a stopped
      // clock manufactures no loads of its own.
      counting = 1'b0;
      if (loads != 0) begin
         $display("ERROR: %0d phantom LF load(s) across a sleep with no write outstanding %t ns", loads, $time);
         error = error + 1;
      end else begin
         $display("PASS:  no phantom LF load across the sleep %t ns", $time);
      end

      $display("");
      $display(" ===============================================");
      $display("|   DEEP SLEEP : STATE AFTER THE WAKE           |");
      $display(" ===============================================");

      // Check IMMEDIATELY: the mirror revalidates on its own within a few LF
      // periods, so the invalid-mirror checks below must run inside that window.
      allow_deep_sleep = 1'b0;

      // Trust must actually have been withdrawn: the mirror is invalid until
      // the refilled pipeline delivers a tick. A mirror still valid here means
      // the IP would serve its pre-sleep value -- exactly what a clock stop has
      // to make impossible, and what distinguishes a correct oscillator
      // controller from one that stops the clock without leaving an edge for
      // hclk_aon_en_i to be observed on.
      if (tb_ahb_aclint.dut.u_mtimer.mirror_valid !== 1'b0) begin
         $display("ERROR: mirror still valid after the wake -- trust was never withdrawn across the sleep %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  trust withdrawn across the sleep (mirror invalid after the wake) %t ns", $time);
      end

      // MTIME_HI returns the snapshot of the last MTIME_LO read, which waiting
      // would not refresh, so it must not stall while the mirror is invalid.
      stall_cycles = 0;
      ahb_read(1, MACHINE, `MTIME_HI_ADDR, 32'h00000000, 2, 0, OK);
      if (stall_cycles != 0) begin
         $display("ERROR: MTIME_HI read stalled %0d cycles while the mirror revalidated %t ns", stall_cycles, $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIME_HI read did not stall while the mirror revalidated %t ns", $time);
      end

      // MTIME must have kept counting through the sleep -- the whole reason it
      // lives in the LF domain.
      stall_cycles = 0;
      read_mtime(after_wake);
      $display("INFO:  first post-wake MTIME read = 0x%h_%h (stalled %0d cycles) %t ns",
               after_wake[63:32], after_wake[31:0], stall_cycles, $time);

      if (after_wake <= before_sleep) begin
         $display("ERROR: MTIME did not advance across the sleep -- 0x%h then 0x%h %t ns",
                  before_sleep, after_wake, $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIME counted through the sleep (+%0d ticks) %t ns",
                  (after_wake - before_sleep), $time);
      end

      // Bounded revalidation. Unbounded would mean the mirror never recovers.
      if (stall_cycles > `LF_CYCLES(5)) begin
         $display("ERROR: post-wake read stalled %0d cycles (> 5 LF periods, %0d) %t ns",
                  stall_cycles, `LF_CYCLES(5), $time);
         error = error + 1;
      end else begin
         $display("PASS:  post-wake read revalidated within %0d cycles %t ns", stall_cycles, $time);
      end

      // Usable again, not merely readable.
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'hFFFFFFFF, 2, OK);
      repeat(`LF_CYCLES(4)) @(posedge free_clk);
      if (tb_ahb_aclint.mtimer_wake_lf !== 1'b0) begin
         $display("ERROR: wake still asserted after the deadline was disarmed %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  block fully usable after the wake %t ns", $time);
      end

      $display("");
      $display(" ===============================================");
      $display("|   DEEP SLEEP : ABORTED ON THE ANNOUNCE        |");
      $display(" ===============================================");

      // Deadline parked so nothing wakes us on its own.
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'hFFFFFFFF, 2, OK);

      guard = 0;
      while ((tb_ahb_aclint.hclk_en === 1'b1) && (guard < `LF_CYCLES(20))) begin
         @(posedge free_clk);
         guard = guard + 1;
      end

      // Release the clock, then take the request back INSIDE the one-edge window
      // between the announcement and the stop. The controller has to cancel the
      // stop rather than see it through: once the clock is gone there is no edge
      // left to sample a new request with, and clk_en_o would sit high over a
      // dead clock. Reacting on the negedge of the announce is deliberate -- a
      // poll on posedge free_clk lands one edge too late to be a cancellation.
      allow_deep_sleep = 1'b1;
      @(negedge tb_ahb_aclint.hclk_aon_en);
      allow_deep_sleep = 1'b0;

      edge_cnt    = 0;
      count_edges = 1'b1;
      #(20 * `ACLINT_LF_HALF_PERIOD);
      count_edges = 1'b0;

      // A stuck oscillator still delivers the one committed edge, so "> 0" is not
      // the question -- the question is whether it kept going afterwards.
      if (edge_cnt < 4) begin
         $display("ERROR: oscillator delivered only %0d edge(s) -- the stop was seen through although the request returned inside the announce window, leaving it stuck off %t ns", edge_cnt, $time);
         error = error + 1;
      end else begin
         $display("PASS:  aborted sleep -- oscillator kept running (%0d edges) %t ns", edge_cnt, $time);
      end

      if (tb_ahb_aclint.hclk_aon_en !== 1'b1) begin
         $display("ERROR: hclk_aon_en did not return after the abort %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  hclk_aon_en re-asserted after the abort %t ns", $time);
      end

      read_mtime(before_sleep);
      repeat(`LF_CYCLES(3)) @(posedge free_clk);
      read_mtime(after_wake);
      if (after_wake <= before_sleep) begin
         $display("ERROR: MTIME did not advance after an aborted sleep %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIME still advancing after an aborted sleep %t ns", $time);
      end

      $display("");
      $display(" ===============================================");
      $display("|   DEEP SLEEP : RESET WHILE THE CLOCK IS OFF   |");
      $display(" ===============================================");

      // This time let it sleep for real.
      guard = 0;
      while ((tb_ahb_aclint.hclk_en === 1'b1) && (guard < `LF_CYCLES(20))) begin
         @(posedge free_clk);
         guard = guard + 1;
      end
      allow_deep_sleep = 1'b1;
      #(4 * `ACLINT_LF_HALF_PERIOD);

      if (tb_ahb_aclint.hclk_aon_en !== 1'b0) begin
         $display("ERROR: could not re-enter deep sleep for the reset case %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  asleep again -- oscillator stopped %t ns", $time);
      end

      // Assert the system reset with no clock anywhere. The oscillator
      // controller presets asynchronously, so the reset itself is what restarts
      // the clock; nothing clocked could have done it.
      edge_cnt    = 0;
      count_edges = 1'b1;
      hresetn     = 1'b0;
      #(8 * `ACLINT_LF_HALF_PERIOD);
      count_edges = 1'b0;

      if (edge_cnt == 0) begin
         $display("ERROR: reset asserted during deep sleep did not restart the oscillator %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  reset during sleep restarted the oscillator asynchronously (%0d edges) %t ns", edge_cnt, $time);
      end

      allow_deep_sleep = 1'b0;
      repeat(`LF_CYCLES(2)) @(posedge free_clk);
      hresetn = 1'b1;
      repeat(`LF_CYCLES(8)) @(posedge free_clk);

      // hresetn disarms MTIMECMP; MTIME lives in the LF domain and is untouched.
      ahb_read(1, MACHINE, `MTIMECMP_LO_ADDR, 32'hFFFFFFFF, 2, 1, OK);
      ahb_read(1, MACHINE, `MTIMECMP_HI_ADDR, 32'hFFFFFFFF, 2, 1, OK);
      read_mtime(after_wake);
      if (after_wake === 64'd0) begin
         $display("ERROR: MTIME reset by a reset-during-sleep -- the LF domain should have survived %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIMECMP disarmed and MTIME survived the reset (0x%h_%h) %t ns",
                  after_wake[63:32], after_wake[31:0], $time);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
