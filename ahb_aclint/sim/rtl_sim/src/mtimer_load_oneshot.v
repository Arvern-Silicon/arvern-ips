//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_load_oneshot
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_load_oneshot
// Module Description : EXACTLY ONE LF LOAD PER MTIME WRITE, AND HI/LO BATCHED
//                      INTO ONE ATOMIC LOAD.
//
//                      The MTIME load request is open-loop: the hclk side
//                      asserts it on one tick and retires it on the next,
//                      counting ticks instead of waiting for an acknowledge.
//                      Two things have to hold for that to be safe, and neither
//                      is visible from the bus:
//
//                        + The LF side must consume the request exactly ONCE.
//                          It is a level, held for a whole tick-to-tick
//                          interval, so a level-sensitive consumer would load on
//                          every clk_lf_i edge in that window.
//                        + Consecutive writes must produce SEPARATE loads. The
//                          request has to fall between them; if it stays high
//                          across both, the second load never happens and the
//                          write is silently lost.
//
//                      The second one is not hypothetical -- it is exactly what
//                      the first implementation of this path did, and a HI-then
//                      -LO pair straddling a tick boundary was enough to trigger
//                      it. Hence the third check: a 64-bit write must reach the
//                      counter as ONE load carrying BOTH halves, not as a
//                      partial update that briefly puts a value on the counter
//                      that firmware never wrote.
//----------------------------------------------------------------------------

integer    loads;
integer    ii;
integer    guard;
reg        counting;
reg        ack_d;
reg [63:0] rb;
reg [63:0] partials;

`define MTIME_LO_ADDR    32'h0040BFF8
`define MTIME_HI_ADDR    32'h0040BFFC
`define MTIMECMP_LO_ADDR 32'h00404000
`define MTIMECMP_HI_ADDR 32'h00404004

initial
   begin
      loads    = 0;
      partials = 0;
      counting = 1'b0;
      ack_d = 1'b0;
      forever begin
         @(posedge free_clk);
         // Rising-edge detect, sampled on free_clk: load_ack_lf is one cycle of
         // clk_lf in asynchronous mode but one cycle of hclk_aon under
         // LF_SYNC_EN, so neither a clk_lf-sampled monitor nor a level test
         // counts correctly in both.
         if (counting && (tb_ahb_aclint.dut.u_mtimer.load_ack_lf === 1'b1) && (ack_d === 1'b0)) begin
            loads = loads + 1;
            // Record what the counter actually took, so a partial (one-half)
            // load is visible rather than being smoothed over by a later
            // correcting load.
            partials = tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_next;
         end
         ack_d = tb_ahb_aclint.dut.u_mtimer.load_ack_lf;
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
      repeat(`LF_CYCLES(4)) @(posedge free_clk);

      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'hFFFFFFFF, 2, OK);
      repeat(`LF_CYCLES(4)) @(posedge free_clk);

      $display(" ===============================================");
      $display("|   MTIME LOAD : EXACTLY ONE PER WRITE          |");
      $display(" ===============================================");

      counting = 1'b1;
      ahb_write(1, MACHINE, `MTIME_HI_ADDR, 32'h00000012, 2, OK);
      ahb_write(1, MACHINE, `MTIME_LO_ADDR, 32'h34000000, 2, OK);
      repeat(`LF_CYCLES(10)) @(posedge free_clk);
      counting = 1'b0;

      if (loads != 1) begin
         $display("ERROR: a single 64-bit MTIME write produced %0d LF loads (expected exactly 1) %t ns", loads, $time);
         error = error + 1;
      end else begin
         $display("PASS:  one 64-bit MTIME write -> exactly one LF load %t ns", $time);
      end

      // The one load must have carried BOTH halves. A partial load would show
      // the new HI with the stale LO (or vice versa).
      if (partials[63:32] !== 32'h00000012 || partials[31:0] !== 32'h34000000) begin
         $display("ERROR: the load was PARTIAL -- counter took 0x%h_%h, firmware wrote 0x00000012_34000000 %t ns",
                  partials[63:32], partials[31:0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  HI and LO batched into one atomic load %t ns", $time);
      end

      $display("");
      $display(" ===============================================");
      $display("|   MTIME LOAD : CONSECUTIVE WRITES SEPARATE    |");
      $display(" ===============================================");

      // Four separate 64-bit writes, each given time to land. Every one must
      // produce its own load: this is the check that the request falls between
      // loads rather than staying asserted across them.
      loads    = 0;
      counting = 1'b1;
      for (ii = 0; ii < 4; ii = ii + 1) begin
         ahb_write(1, MACHINE, `MTIME_HI_ADDR, 32'h00000020 + ii, 2, OK);
         ahb_write(1, MACHINE, `MTIME_LO_ADDR, 32'h50000000,      2, OK);
         repeat(`LF_CYCLES(6)) @(posedge free_clk);
      end
      counting = 1'b0;

      if (loads != 4) begin
         $display("ERROR: 4 MTIME writes produced %0d LF loads (expected 4) -- a write was swallowed %t ns", loads, $time);
         error = error + 1;
      end else begin
         $display("PASS:  4 separate MTIME writes -> 4 separate LF loads %t ns", $time);
      end

      // The last one must be what is on the counter.
      repeat(`LF_CYCLES(4)) @(posedge free_clk);
      read_mtime(rb);
      if ((rb[63:32] !== 32'h00000023) || (rb[31:0] < 32'h50000000) ||
          (rb[31:0] > 32'h50000000 + 32'd1000)) begin
         $display("ERROR: MTIME does not hold the LAST write -- 0x%h_%h, expected 0x00000023_5000xxxx %t ns",
                  rb[63:32], rb[31:0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIME holds the last of a run of writes %t ns", $time);
      end

      $display("");
      $display(" ===============================================");
      $display("|   MTIME LOAD : BACK-TO-BACK, NO SETTLE TIME   |");
      $display(" ===============================================");

      // Hammer with no gap at all, so pairs land on both sides of tick
      // boundaries. Whatever the load count, the counter must end up holding the
      // final value -- nothing may be left half-applied.
      loads    = 0;
      counting = 1'b1;
      for (ii = 0; ii < 8; ii = ii + 1) begin
         ahb_write(1, MACHINE, `MTIME_HI_ADDR, 32'h00000030 + ii, 2, OK);
         ahb_write(1, MACHINE, `MTIME_LO_ADDR, 32'h60000000 + ii, 2, OK);
      end
      repeat(`LF_CYCLES(10)) @(posedge free_clk);
      counting = 1'b0;
      $display("INFO:  16 back-to-back half-writes produced %0d LF loads %t ns", loads, $time);

      read_mtime(rb);
      if ((rb[63:32] !== 32'h00000037) || (rb[31:0] < 32'h60000007) ||
          (rb[31:0] > 32'h60000007 + 32'd1000)) begin
         $display("ERROR: back-to-back MTIME writes left the counter wrong -- 0x%h_%h, expected 0x00000037_6000000x %t ns",
                  rb[63:32], rb[31:0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  back-to-back MTIME writes converge on the final value %t ns", $time);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
