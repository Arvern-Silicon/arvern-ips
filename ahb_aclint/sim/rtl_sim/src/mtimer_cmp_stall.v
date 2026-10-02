//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_cmp_stall
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_cmp_stall.v
// Module Description : MTIMECMP WRITES MUST NEVER BACK-PRESSURE THE BUS.
//
//                      Stage 1 of the MTIMECMP write shadow accepts a write on
//                      any cycle and stage 2 hands it to the LF domain on the
//                      next tick, so there is nothing for a write to wait on.
//                      Hammer the same half far faster than the LF domain can
//                      consume it and assert that hreadyout_o never once drops,
//                      and that the value that survives is the LAST one
//                      written. Repeated writes to one half while the previous
//                      value is still crossing are the pattern a handshaked
//                      crossing would have to stall, so it is the one guarded.
//----------------------------------------------------------------------------

integer    ii;
integer    stall_cycles;
reg        measure;
reg [31:0] rb;

`define MTIMECMP_LO_ADDR 32'h00404000
`define MTIMECMP_HI_ADDR 32'h00404004

// Count every cycle hreadyout_o is low while the burst is in flight. Sampled on
// free_clk because hclk_i may be gated between phases.
initial
   begin
      stall_cycles = 0;
      measure      = 1'b0;
      forever begin
         @(posedge free_clk);
         if (measure && (tb_ahb_aclint.dut.hreadyout_o === 1'b0))
            stall_cycles = stall_cycles + 1;
      end
   end

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      // Scaled with the LF ratio, not a fixed cycle count. MTIME is genuinely
      // unreadable for the first few LF periods after reset: the read mirror has
      // never been loaded, and the observer only declares itself trustworthy
      // once its sampling pipeline is refilled. A raw cycle count is
      // ample at a fast ratio and far too short at a realistic one.
      repeat(`LF_CYCLES(5)) @(posedge free_clk);

      $display(" ===============================================");
      $display("|   MTIMECMP : WRITES NEVER STALL THE BUS       |");
      $display(" ===============================================");

      // Sixteen back-to-back writes to the SAME half, with no gap. At R = 10
      // that is well over an LF period of traffic, so under the old design the
      // second write alone would have blocked for thousands of cycles.
      measure = 1'b1;
      for (ii = 0; ii < 16; ii = ii + 1) begin
         ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'h10000000 + ii, 2, OK);
      end
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, 32'h00000042, 2, OK);
      measure = 1'b0;

      if (stall_cycles != 0) begin
         $display("ERROR: MTIMECMP write burst stalled the bus for %0d cycles -- writes must be zero-wait-state %t ns",
                  stall_cycles, $time);
         error = error + 1;
      end else begin
         $display("PASS:  17 back-to-back MTIMECMP writes, zero wait states %t ns", $time);
      end

      // Read-back is from stage 1, so the last value written is visible
      // immediately -- no waiting for the LF domain.
      ahb_read(1, MACHINE, `MTIMECMP_LO_ADDR, 32'h1000000F, 2, 0, OK);
      ahb_read(1, MACHINE, `MTIMECMP_HI_ADDR, 32'h00000042, 2, 0, OK);
      $display("PASS:  MTIMECMP read-back returns the last value written %t ns", $time);

      // And the LF-resident copy must converge on that same last value once a
      // tick has carried it across. This is the half that actually feeds the
      // comparator, so a stage-1-only update would be a silent trap.
      repeat(`LF_CYCLES(4)) @(posedge free_clk);
      if (tb_ahb_aclint.dut.u_mtimer.mtimecmp_cmp[31:0] !== 32'h1000000F) begin
         $display("ERROR: LF-resident MTIMECMP_LO did not take the last written value -- got 0x%h expected 0x1000000F %t ns",
                  tb_ahb_aclint.dut.u_mtimer.mtimecmp_cmp[31:0], $time);
         error = error + 1;
      end else if (tb_ahb_aclint.dut.u_mtimer.mtimecmp_cmp[63:32] !== 32'h00000042) begin
         $display("ERROR: LF-resident MTIMECMP_HI did not take the last written value -- got 0x%h expected 0x00000042 %t ns",
                  tb_ahb_aclint.dut.u_mtimer.mtimecmp_cmp[63:32], $time);
         error = error + 1;
      end else begin
         $display("PASS:  LF-resident MTIMECMP converged on the last written value %t ns", $time);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
