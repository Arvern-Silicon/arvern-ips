//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_hart_hi
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_hart_hi
// Module Description : High-index per-hart MTIMER muxing. mtimer_multihart caps
//                      the tested harts at 4 for runtime, so at NUM_HARTS=16
//                      the comparator / CDC slices / IRQ bits for harts 4..15
//                      are never selected there. This test programs the TOP hart
//                      (NUM_HARTS-1) and a mid hart, verifies their MTIP fire
//                      while an unprogrammed low hart stays quiet -- catching a
//                      slice/decode bug at a high hart_idx. Intended for the
//                      nh16 config (requires NUM_HARTS >= 8).
//----------------------------------------------------------------------------

localparam HART_TOP = NUM_HARTS - 1;
localparam HART_MID = NUM_HARTS / 2;

wire [31:0] mtime_lo_addr = 32'h0040BFF8;
wire [31:0] mtime_hi_addr = mtime_lo_addr + 32'h4;

reg  [63:0] t_now;
reg  [63:0] target_top;
reg  [63:0] target_mid;
integer     poll_count;
reg         irq_seen;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);

      if (NUM_HARTS < 8) begin
         tb_skip_finish("mtimer_hart_hi requires NUM_HARTS >= 8 (run at nh16)");
      end

      repeat(20) @(posedge free_clk);

      $display(" ===============================================");
      $display("|     MTIMER : HIGH-INDEX HART (top/mid)        |");
      $display(" ===============================================");
      $display("INFO:  NUM_HARTS=%0d  HART_TOP=%0d  HART_MID=%0d", NUM_HARTS, HART_TOP, HART_MID);

      // Park top + mid comparators at max so nothing matches during setup.
      ahb_write(1, MACHINE, 32'h00404004 + (32'h8 * HART_TOP), 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, 32'h00404000 + (32'h8 * HART_TOP), 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, 32'h00404004 + (32'h8 * HART_MID), 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, 32'h00404000 + (32'h8 * HART_MID), 32'hFFFFFFFF, 2, OK);
      repeat(60) @(posedge free_clk);

      // Snapshot MTIME and program both programmed harts slightly ahead.
      // Sample the reconstructed snapshot AFTER the pair, never between the two
      // reads: the LO read is what loads it, and since a MTIME read completes
      // in a single cycle, sampling in between races the mirror's own clock edge
      // and returns the PREVIOUS snapshot (which out of reset is zero).
      ahb_read(1, MACHINE, mtime_lo_addr, 32'h00000000, 2, 0, OK);
      ahb_read(1, MACHINE, mtime_hi_addr, 32'h00000000, 2, 0, OK);
      t_now = tb_ahb_aclint.mtime_shadow_ahb_sim;
      $display("INFO:  t_now = 0x%h_%h %t ns", t_now[63:32], t_now[31:0], $time);

      target_top = t_now + 64'd50;
      target_mid = t_now + 64'd90;

      ahb_write(1, MACHINE, 32'h00404000 + (32'h8 * HART_TOP), target_top[31:0],  2, OK);
      ahb_write(1, MACHINE, 32'h00404004 + (32'h8 * HART_TOP), target_top[63:32], 2, OK);
      ahb_write(1, MACHINE, 32'h00404000 + (32'h8 * HART_MID), target_mid[31:0],  2, OK);
      ahb_write(1, MACHINE, 32'h00404004 + (32'h8 * HART_MID), target_mid[63:32], 2, OK);
      repeat(40) @(posedge free_clk);

      // The TOP hart must fire (this is the high-index mux/slice under test).
      irq_seen   = 1'b0;
      poll_count = 0;
      begin : POLL_TOP
         repeat (`LF_CYCLES(150)) begin
            @(posedge free_clk);
            poll_count = poll_count + 1;
            if (tb_ahb_aclint.dut.irq_m_timer_o[HART_TOP] == 1'b1) begin
               irq_seen = 1'b1;
               disable POLL_TOP;
            end
         end
      end
      if (irq_seen) begin
         $display("PASS:  irq_m_timer_o[%0d] (TOP) asserted after %0d cycles %t ns", HART_TOP, poll_count, $time);
      end else begin
         $display("ERROR: irq_m_timer_o[%0d] (TOP) never asserted -- high-index mux/slice broken %t ns", HART_TOP, $time);
         error = error + 1;
      end

      // Unprogrammed low hart 1 must NOT have fired (parked at reset 0xFFFF...).
      if (tb_ahb_aclint.dut.irq_m_timer_o[1] !== 1'b0) begin
         $display("ERROR: irq_m_timer_o[1] asserted but was never programmed -- cross-hart leak %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_timer_o[1] (unprogrammed) stayed low %t ns", $time);
      end

      // The mid hart fires 40 LF ticks after the top one. Poll rather than
      // waiting a fixed number of free_clk cycles: the deadline is expressed in
      // LF ticks, so a raw cycle count silently becomes too short whenever the
      // clk_lf:hclk ratio is raised.
      irq_seen   = 1'b0;
      poll_count = 0;
      begin : POLL_MID
         repeat (`LF_CYCLES(150)) begin
            @(posedge free_clk);
            poll_count = poll_count + 1;
            if (tb_ahb_aclint.dut.irq_m_timer_o[HART_MID] == 1'b1) begin
               irq_seen = 1'b1;
               disable POLL_MID;
            end
         end
      end
      if (!irq_seen) begin
         $display("ERROR: irq_m_timer_o[%0d] (MID) not asserted at end-of-test %t ns", HART_MID, $time);
         $display("INFO:  MID  programmed 0x%h_%h  LF-resident 0x%h  mtime 0x%h",
                  target_mid[63:32], target_mid[31:0],
                  tb_ahb_aclint.dut.u_mtimer.mtimecmp_cmp[64*HART_MID +: 64],
                  tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_lf);
         $display("INFO:  TOP  programmed 0x%h_%h  LF-resident 0x%h",
                  target_top[63:32], target_top[31:0],
                  tb_ahb_aclint.dut.u_mtimer.mtimecmp_cmp[64*HART_TOP +: 64]);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_timer_o[%0d] (MID) asserted after %0d cycles %t ns", HART_MID, poll_count, $time);
      end

      // Cleanup.
      ahb_write(1, MACHINE, 32'h00404000 + (32'h8 * HART_TOP), 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, 32'h00404004 + (32'h8 * HART_TOP), 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, 32'h00404000 + (32'h8 * HART_MID), 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, 32'h00404004 + (32'h8 * HART_MID), 32'hFFFFFFFF, 2, OK);
      repeat(40) @(posedge free_clk);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
