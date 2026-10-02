//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_mtime_write
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_mtime_write.v
// Module Description : MTIME is a read-write register (ACLINT 1.0-rc4 Section
//                      2.2). Covers the write path end to end:
//                        1. write both halves, read back (counter keeps
//                           ticking, so readback is written+drift, never less)
//                        2. a forward load past MTIMECMP raises MTIP
//                        3. a backwards load lowers it again -- the comparator
//                           is combinational on the loaded value, not sticky
//                        4. reads taken while a load is in flight return the
//                           pending write value, never a torn one
//----------------------------------------------------------------------------

reg [63:0] rb;
reg [63:0] rb2;
reg [63:0] target;
integer    ii;
integer    stall_seen;
integer    stall_run;
integer    stall_max;
reg        measure_stall;

// Longest unbroken hreadyout_o low run, sampled only while phase 4 is driving
// reads straight into a pending write. Any stall here is charged to the AHB
// master, not absorbed in the background; with pending-write forwarding it must
// stay below the two-LF-period bound checked at the end of phase 4.
initial
   begin
      stall_run     = 0;
      stall_max     = 0;
      measure_stall = 1'b0;
      forever begin
         @(posedge free_clk);
         if (measure_stall) begin
            if (tb_ahb_aclint.dut.hreadyout_o == 1'b0) begin
               stall_run = stall_run + 1;
               if (stall_run > stall_max) stall_max = stall_run;
            end else begin
               stall_run = 0;
            end
         end
      end
   end

`define MTIME_LO_ADDR    32'h0040BFF8
`define MTIME_HI_ADDR    32'h0040BFFC
`define MTIMECMP_LO_ADDR 32'h00404000
`define MTIMECMP_HI_ADDR 32'h00404004

// Read a coherent 64-bit MTIME: the LO read latches the snapshot, HI returns the
// buffered upper half.
task read_mtime;
   output [63:0] val;
   begin
      ahb_read(1, MACHINE, `MTIME_LO_ADDR, 32'h00000000, 2, 0, OK);
      ahb_read(1, MACHINE, `MTIME_HI_ADDR, 32'h00000000, 2, 0, OK);
      // Sample the reconstructed snapshot AFTER the pair. The LO read is what
      // loads it, but with pending-write forwarding a LO read can complete in a
      // single cycle -- sampling between the two reads races the mirror's own
      // clock edge and returns the PREVIOUS snapshot.
      val = tb_ahb_aclint.mtime_shadow_ahb_sim;
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(100) @(posedge free_clk);

      // Park MTIMECMP out of reach so MTIP cannot fire during phase 1.
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'hFFFFFFFF, 2, OK);

      $display(" ===============================================");
      $display("|      MTIME : WRITE + READBACK                 |");
      $display(" ===============================================");

      // Write HI first then LO: the counter carries LO->HI between the two
      // independently loaded halves, so writing LO last keeps the pair coherent.
      target = 64'h0000002A_10000000;
      ahb_write(1, MACHINE, `MTIME_HI_ADDR, target[63:32], 2, OK);
      ahb_write(1, MACHINE, `MTIME_LO_ADDR, target[31:0],  2, OK);

      repeat(400) @(posedge free_clk);
      read_mtime(rb);
      $display("INFO:  wrote 0x%h_%h, read back 0x%h_%h %t ns",
               target[63:32], target[31:0], rb[63:32], rb[31:0], $time);

      // The counter never stops, so the readback is the written value plus a
      // small drift -- but it must never be below what was written, and must
      // stay in the same neighbourhood (a failed load would read ~0).
      if (rb < target) begin
         $display("ERROR: MTIME readback below the written value -- wrote 0x%h read 0x%h %t ns",
                  target, rb, $time);
         error = error + 1;
      end else if ((rb - target) > 64'd10000) begin
         $display("ERROR: MTIME readback too far from the written value -- wrote 0x%h read 0x%h %t ns",
                  target, rb, $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIME took the written value (drift = %0d LF ticks) %t ns",
                  (rb - target), $time);
      end

      // Still counting after the load. LF-relative: while a load is pending a
      // read is served from the pending-write registers and legitimately does
      // NOT advance -- the counter has not loaded yet. The gap must therefore
      // outlast the load latency (a few clk_lf_i periods) and leave real ticks
      // on top, or at a slow ratio both samples land inside the forwarding
      // window and look like a stopped counter.
      repeat(`LF_CYCLES(20)) @(posedge free_clk);
      read_mtime(rb2);
      if (rb2 <= rb) begin
         $display("ERROR: MTIME stopped counting after a write -- 0x%h then 0x%h %t ns", rb, rb2, $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIME still counting after a write %t ns", $time);
      end

      $display("");
      $display(" ===============================================");
      $display("|      MTIME : FORWARD LOAD RAISES MTIP         |");
      $display(" ===============================================");

      // Arm MTIMECMP just above the current count, then jump MTIME past it.
      read_mtime(rb);
      target = rb + 64'd1000;
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, target[63:32], 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, target[31:0],  2, OK);
      repeat(50) @(posedge free_clk);

      if (tb_ahb_aclint.dut.irq_m_timer_o != 1'b0) begin
         $display("ERROR: MTIP already set before the forward load %t ns", $time);
         error = error + 1;
      end

      // Jump MTIME well past MTIMECMP.
      target = target + 64'd5000;
      ahb_write(1, MACHINE, `MTIME_HI_ADDR, target[63:32], 2, OK);
      ahb_write(1, MACHINE, `MTIME_LO_ADDR, target[31:0],  2, OK);

      stall_seen = 0;
      for (ii = 0; ii < 2000; ii = ii + 1) begin
         @(posedge free_clk);
         if (tb_ahb_aclint.dut.irq_m_timer_o == 1'b1) begin
            stall_seen = 1;
            ii = 2000;
         end
      end

      if (stall_seen) begin
         $display("PASS:  MTIP asserted after a forward MTIME load %t ns", $time);
      end else begin
         $display("ERROR: MTIP did not assert after loading MTIME past MTIMECMP %t ns", $time);
         error = error + 1;
      end

      $display("");
      $display(" ===============================================");
      $display("|      MTIME : BACKWARDS LOAD CLEARS MTIP       |");
      $display(" ===============================================");

      // Rewind MTIME below MTIMECMP. The comparator is combinational on the
      // loaded value, so MTIP must drop rather than latch.
      target = target - 64'd20000;
      ahb_write(1, MACHINE, `MTIME_HI_ADDR, target[63:32], 2, OK);
      ahb_write(1, MACHINE, `MTIME_LO_ADDR, target[31:0],  2, OK);

      stall_seen = 0;
      for (ii = 0; ii < 2000; ii = ii + 1) begin
         @(posedge free_clk);
         if (tb_ahb_aclint.dut.irq_m_timer_o == 1'b0) begin
            stall_seen = 1;
            ii = 2000;
         end
      end

      if (stall_seen) begin
         $display("PASS:  MTIP cleared after a backwards MTIME load %t ns", $time);
      end else begin
         $display("ERROR: MTIP stayed asserted after rewinding MTIME below MTIMECMP %t ns", $time);
         error = error + 1;
      end

      $display("");
      $display(" ===============================================");
      $display("|      MTIME : READ ACROSS AN IN-FLIGHT LOAD    |");
      $display(" ===============================================");

      // Park MTIMECMP again so MTIP does not interfere.
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'hFFFFFFFF, 2, OK);

      // A read issued right behind a write must return old-or-new, never a
      // mix of pre- and post-load bits. The mirror only moves on a tick, so
      // it is never sampled mid-update; reads inside the crossing window are
      // served from the pending write value instead.
      target = 64'h00000055_20000000;
      measure_stall = 1'b1;
      ahb_write(1, MACHINE, `MTIME_HI_ADDR, target[63:32], 2, OK);
      ahb_write(1, MACHINE, `MTIME_LO_ADDR, target[31:0],  2, OK);

      // Immediately read back-to-back, with no settling delay.
      for (ii = 0; ii < 8; ii = ii + 1) begin
         read_mtime(rb);
         if ((rb < target) || ((rb - target) > 64'd10000)) begin
            $display("ERROR: corrupt MTIME sample across an in-flight load -- 0x%h_%h (expected near 0x%h_%h) %t ns",
                     rb[63:32], rb[31:0], target[63:32], target[31:0], $time);
            error = error + 1;
         end
      end
      measure_stall = 1'b0;
      $display("PASS:  no corrupt MTIME sample across an in-flight load %t ns", $time);
      $display("INFO:  longest hreadyout_o low run while reading into a pending write = %0d hclk cycles %t ns",
               stall_max, $time);

      // PENDING-WRITE FORWARDING. A read taken while both halves of an MTIME
      // write are still crossing is served from the hclk-domain write registers
      // instead of waiting for the load to reach the counter, so it must NOT cost
      // anything like a clk_lf_i period. Waiting for the load would cost several
      // LF periods, thousands of hclk at a realistic ratio -- the bound below is
      // expressed in LF periods so it scales with ACLINT_LF_HALF_PERIOD and
      // fails loudly at any ratio if the forwarding path regresses.
      if (stall_max >= `LF_CYCLES(2)) begin
         $display("ERROR: read into a pending MTIME write stalled %0d hclk cycles (>= two clk_lf_i periods, %0d) -- forwarding not working %t ns",
                  stall_max, `LF_CYCLES(2), $time);
         error = error + 1;
      end else begin
         $display("PASS:  read into a pending MTIME write served without waiting for the LF load (%0d < %0d hclk) %t ns",
                  stall_max, `LF_CYCLES(2), $time);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
