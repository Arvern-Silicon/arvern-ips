//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_deep_sleep_zero_edge
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_deep_sleep_zero_edge.v
// Module Description : DEEP SLEEP BEHIND A CONTROLLER THAT BREAKS THE
//                      hclk_aon_en_i CONTRACT.
//
//                      ahb_aclint.v: hclk_aon_en_i is "deasserted synchronously
//                      one edge BEFORE the clock stops". arv_osc_ctrl meets that
//                      by construction; ACLINT_OSC_ZERO_EDGE (defined below, read
//                      by the bench) makes the oscillator stop on the announce
//                      itself, so no edge follows it. This pins what the edge is
//                      for, and what still holds without it:
//
//                        1. the model delivers zero hclk_aon edges with the
//                           announce low (the test would prove nothing otherwise);
//                        2. the edge is what clears the trust state before the
//                           stop: with ASYNC_RST_EN=0 the mirror is still VALID
//                           when the wake arrives (with ASYNC_RST_EN=1 the level
//                           alone clears it);
//                        3. the trust reset is released through its synchroniser,
//                           two edges after the wake, so those two edges clear
//                           the mirror in either reset style and no LF tick is
//                           emitted before trust returns;
//                        4. MTIME reads correctly after the wake.
//
//                      Waits spanning the sleep use # delays: free_clk IS the
//                      oscillator.
//----------------------------------------------------------------------------
`define ACLINT_OSC_ZERO_EDGE

`define MTIME_LO_ADDR    32'h0040BFF8
`define MTIME_HI_ADDR    32'h0040BFFC
`define MTIMECMP_LO_ADDR 32'h00404000
`define MTIMECMP_HI_ADDR 32'h00404004

reg [63:0] zs_before;
reg [63:0] zs_after;
reg [31:0] zs_deadline;
integer    zs_guard;
integer    zs_asleep;
integer    zs_low_edges;
integer    zs_ticks;
reg        zs_watch;
reg        zs_after_wake;
reg        zs_mv_at_wake;

// Edges delivered while the announce is low (sampled before the edge's own
// updates, so the announcing edge itself does not count).
initial begin
   zs_low_edges = 0;
   zs_ticks     = 0;
   zs_watch     = 1'b0;
   zs_after_wake = 1'b0;
   forever begin
      @(posedge free_clk);
      if (zs_watch && (tb_ahb_aclint.hclk_aon_en === 1'b0)) zs_low_edges = zs_low_edges + 1;
      if (zs_after_wake && (tb_ahb_aclint.dut.u_mtimer.lf_trust_rstn !== 1'b1) &&
          (tb_ahb_aclint.dut.u_mtimer.lf_tick === 1'b1))
         zs_ticks = zs_ticks + 1;
   end
end

// The mirror at the instant the oscillator is woken, before any edge: the first
// post-wake edge already clears it, so a polled check would be too late.
initial begin
   zs_mv_at_wake = 1'bx;
   wait (zs_watch === 1'b1);
   @(negedge tb_ahb_aclint.hclk_aon_en);
   @(posedge tb_ahb_aclint.hclk_aon_en);
   zs_mv_at_wake = tb_ahb_aclint.dut.u_mtimer.mirror_valid;
   zs_after_wake = 1'b1;                     // watch for ticks from the wake on
end

task zs_read_mtime;
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
         tb_skip_finish("mtimer_deep_sleep_zero_edge needs an LF-resident timebase (LF_SYNC_EN=0)");
      end

      repeat(`LF_CYCLES(6)) @(posedge free_clk);

      $display(" ===============================================");
      $display("|  DEEP SLEEP, OSCILLATOR STOPS ON THE ANNOUNCE |");
      $display(" ===============================================");

      zs_read_mtime(zs_before);
      zs_deadline = zs_before[31:0] + 32'd40;
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, zs_before[63:32], 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, zs_deadline,      2, OK);
      repeat(`LF_CYCLES(4)) @(posedge free_clk);

      zs_watch         = 1'b1;
      allow_deep_sleep = 1'b1;
      zs_guard = 0;
      while ((tb_ahb_aclint.hclk_en === 1'b1) && (zs_guard < `LF_CYCLES(20))) begin
         @(posedge free_clk);
         zs_guard = zs_guard + 1;
      end

      #2000;
      if (tb_ahb_aclint.hclk_aon_en !== 1'b0) begin
         $display("ERROR: oscillator still running with every clock request released %t ns", $time);
         error = error + 1;
      end

      zs_asleep = 0;
      while ((tb_ahb_aclint.hclk_aon_en !== 1'b1) && (zs_asleep < 200*`ACLINT_LF_HALF_PERIOD)) begin
         #100;
         zs_asleep = zs_asleep + 100;
      end
      zs_watch = 1'b0;
      if (tb_ahb_aclint.hclk_aon_en !== 1'b1) begin
         $display("ERROR: the deadline never woke the oscillator %t ns", $time);
         error = error + 1;
      end

      // (1) the model
      if (zs_low_edges != 0) begin
         $display("ERROR: the zero-edge model delivered %0d edge(s) with hclk_aon_en low %t ns", zs_low_edges, $time);
         error = error + 1;
      end else
         $display("PASS:  no hclk_aon edge was delivered with hclk_aon_en low %t ns", $time);

      // (2) at the wake, before any edge: the announce level alone clears the trust
      // state only with asynchronous resets.
      if (ASYNC_RST_EN != 0) begin
         if (zs_mv_at_wake !== 1'b0) begin
            $display("ERROR: ASYNC_RST_EN=1 -- mirror still valid at the wake although the announce level resets it %t ns", $time);
            error = error + 1;
         end else
            $display("PASS:  ASYNC_RST_EN=1 -- the announce level alone cleared the mirror %t ns", $time);
      end else begin
         if (zs_mv_at_wake !== 1'b1) begin
            $display("ERROR: ASYNC_RST_EN=0 -- mirror cleared with no edge after the announce; the contract edge would not be needed %t ns", $time);
            error = error + 1;
         end else
            $display("PASS:  ASYNC_RST_EN=0 -- mirror still valid at the wake: the contract edge is what clears it before the stop %t ns", $time);
      end

      // (3) the synchroniser holds trust for two edges after the wake
      repeat(3) @(posedge free_clk);
      #1;
      if (tb_ahb_aclint.dut.u_mtimer.mirror_valid !== 1'b0) begin
         $display("ERROR: mirror still valid after the post-wake synchroniser edges %t ns", $time);
         error = error + 1;
      end else
         $display("PASS:  mirror cleared by the post-wake synchroniser edges %t ns", $time);
      while (tb_ahb_aclint.dut.u_mtimer.lf_trust_rstn !== 1'b1) @(posedge free_clk);
      zs_after_wake = 1'b0;
      if (zs_ticks != 0) begin
         $display("ERROR: %0d LF tick(s) emitted before trust returned %t ns", zs_ticks, $time);
         error = error + 1;
      end else
         $display("PASS:  no LF tick before trust returned %t ns", $time);

      // (4) MTIME after the wake
      allow_deep_sleep = 1'b0;
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, 32'hFFFFFFFF, 2, OK);
      zs_read_mtime(zs_after);
      if (zs_after <= zs_before + 64'd30) begin
         $display("ERROR: MTIME did not advance across the sleep -- 0x%h then 0x%h %t ns", zs_before, zs_after, $time);
         error = error + 1;
      end else
         $display("PASS:  MTIME advanced across the sleep (0x%h -> 0x%h) %t ns", zs_before, zs_after, $time);

      repeat(`LF_CYCLES(2)) @(posedge free_clk);
      stimulus_done = 1;
   end
