//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_mtime_write_tick_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_mtime_write_tick_walk.v
// Module Description : AN MTIME WRITE AT EVERY POSITION OF THE LF TICK CYCLE.
//
//                      An MTIME write is parked on the hclk side and handed to the
//                      counter on a later, QUIET LF tick (no write since the
//                      previous one), so a HI-then-LO pair becomes one atomic load;
//                      a write landing on the launch tick itself belongs to the
//                      NEXT load. ahb_aclint.md: the counter takes the written
//                      value "two to three LF periods" after the write. Existing
//                      tests reach the same-cycle cases only by chance alignment;
//                      this walks the write across the whole tick period.
//
//                      Every written value is TAGGED: HI = 0xA0 + tag and
//                      LO[31:24] = tag, so any value the counter takes whose two
//                      halves disagree is a torn / merged load firmware never
//                      wrote (a monitor checks every counter change).
//
//                        A. a HI+LO pair issued d hclk cycles after a tick,
//                           d = 0..R-1: the counter lands on it within 3 LF
//                           periods, no torn value;
//                        B. a pair, then -- after the next, non-quiet tick -- a
//                           LO-only write walked across the following interval
//                           (d = 0..R+2: bus wait states quantise the offset), so
//                           that at one offset it lands on the launch tick of the
//                           pair: the counter ends on {pair HI, new LO}, no torn
//                           value, an AHB read in the meantime returns the new LO,
//                           and the same-cycle corner is proven to have occurred.
//----------------------------------------------------------------------------

`define MTIME_LO_ADDR    32'h0040BFF8
`define MTIME_HI_ADDR    32'h0040BFFC
`define MTIMECMP_LO_ADDR 32'h00404000
`define MTIMECMP_HI_ADDR 32'h00404004

integer    tw_d;
integer    tw_tag;
integer    tw_wait;
integer    tw_torn;
integer    tw_coincide;
integer    tw_rounds;
reg        tw_check;
reg [63:0] tw_cnt;
reg [31:0] tw_rd;

// Torn-value monitor: every value the counter takes must have matching tags.
initial begin
   tw_torn  = 0;
   tw_check = 1'b0;
end
always @(tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_lf) begin
   tw_cnt = tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_lf;
   if (tw_check && (tw_cnt[63:32] != (32'hA0 + {24'h0, tw_cnt[31:24]}))) begin
      tw_torn = tw_torn + 1;
      $display("ERROR: counter took 0x%h_%h -- HI and LO tags disagree (a value firmware never wrote) %t ns",
               tw_cnt[63:32], tw_cnt[31:0], $time);
   end
end

// Same-cycle corner: an MTIME_LO write strobe on an LF tick cycle (both sampled
// mid-cycle, so the comparison is within one cycle whatever the process order).
initial tw_coincide = 0;
always @(negedge free_clk)
   if ((tb_ahb_aclint.dut.u_mtimer.mtime_lo_wr === 1'b1) && (tb_ahb_aclint.dut.u_mtimer.lf_tick === 1'b1))
      tw_coincide = tw_coincide + 1;

task tw_read_lo;
   output [31:0] val;
   begin
      ahb_read(1, MACHINE, `MTIME_LO_ADDR, 32'h00000000, 2, 0, OK);
      ahb_read(1, MACHINE, `MTIME_HI_ADDR, 32'h00000000, 2, 0, OK);   // the bench shadow updates on the pair
      val = tb_ahb_aclint.mtime_shadow_ahb_sim[31:0];
   end
endtask

// Wait until the counter holds {hi, lo-and-above}: bounded by 3 LF periods plus a
// few hclk cycles, counted from the end of the last write.
task tw_wait_landed;
   input [31:0] hi;
   input [31:0] lo;
   input [8*24:1] what;
   begin
      tw_wait = 0;
      while (((tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_lf[63:32] !== hi) ||
              (tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_lf[31:0]   <  lo) ||
              (tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_lf[31:0]   >  lo + 32'd8)) &&
             (tw_wait < `LF_CYCLES(3) + 16)) begin
         @(negedge free_clk);
         tw_wait = tw_wait + 1;
      end
      if (tw_wait >= `LF_CYCLES(3) + 16) begin
         $display("ERROR: %0s d=%0d -- counter 0x%h_%h did not take 0x%h_%h within 3 LF periods %t ns",
                  what, tw_d, tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_lf[63:32],
                  tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_lf[31:0], hi, lo, $time);
         error = error + 1;
      end
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(`LF_CYCLES(6)) @(posedge free_clk);

      // MTIME is thrown around below: keep MTIP out of the way.
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'hFFFFFFFF, 2, OK);

      // Start from a tagged value so the torn monitor can run throughout.
      ahb_write(1, MACHINE, `MTIME_HI_ADDR, 32'hA0, 2, OK);
      ahb_write(1, MACHINE, `MTIME_LO_ADDR, 32'h00000000, 2, OK);
      tw_d = -1;
      tw_wait_landed(32'hA0, 32'h00000000, "initial");
      tw_check  = 1'b1;
      tw_rounds = 0;

      $display(" ===============================================");
      $display("|  A: HI+LO PAIR AT EVERY TICK OFFSET           |");
      $display(" ===============================================");
      for (tw_d = 0; tw_d < `LF_RATIO; tw_d = tw_d + 1) begin
         tw_tag = 1 + tw_d;
         @(posedge tb_ahb_aclint.dut.u_mtimer.lf_tick);
         repeat (tw_d) @(negedge free_clk);
         ahb_write(1, MACHINE, `MTIME_HI_ADDR, 32'hA0 + tw_tag, 2, OK);
         ahb_write(1, MACHINE, `MTIME_LO_ADDR, tw_tag << 24,    2, OK);
         tw_wait_landed(32'hA0 + tw_tag, tw_tag << 24, "pair");
         tw_rounds = tw_rounds + 1;
      end

      $display(" ===============================================");
      $display("|  B: LO WRITE WALKED ACROSS THE LAUNCH TICK    |");
      $display(" ===============================================");
      tw_coincide = 0;
      for (tw_d = 0; tw_d < `LF_RATIO + 3; tw_d = tw_d + 1) begin
         tw_tag = 64 + tw_d;
         ahb_write(1, MACHINE, `MTIME_HI_ADDR, 32'hA0 + tw_tag, 2, OK);
         ahb_write(1, MACHINE, `MTIME_LO_ADDR, tw_tag << 24,    2, OK);
         @(posedge tb_ahb_aclint.dut.u_mtimer.lf_tick);        // non-quiet: no launch
         repeat (tw_d) @(negedge free_clk);
         ahb_write(1, MACHINE, `MTIME_LO_ADDR, (tw_tag << 24) | 32'h00800000, 2, OK);
         tw_read_lo(tw_rd);
         if ((tw_rd[31:24] !== tw_tag[7:0]) || (tw_rd[23:0] < 24'h800000)) begin
            $display("ERROR: B d=%0d -- AHB read 0x%h while the LO write was pending (expected >= 0x%h) %t ns",
                     tw_d, tw_rd, (tw_tag << 24) | 32'h00800000, $time);
            error = error + 1;
         end
         tw_wait_landed(32'hA0 + tw_tag, (tw_tag << 24) | 32'h00800000, "pair+LO");
         tw_rounds = tw_rounds + 1;
      end

      tw_check = 1'b0;
      if (tw_torn != 0) begin
         $display("ERROR: %0d torn counter value(s) across the walk %t ns", tw_torn, $time);
         error = error + 1;
      end else
         $display("PASS:  %0d rounds, the counter only ever took written values %t ns", tw_rounds, $time);
      if (tw_coincide == 0) begin
         $display("ERROR: no LO write strobe ever landed on a tick cycle -- the walk missed its corner %t ns", $time);
         error = error + 1;
      end else
         $display("PASS:  an MTIME_LO write landed on a tick cycle %0d time(s) %t ns", tw_coincide, $time);

      repeat(`LF_CYCLES(2)) @(posedge free_clk);
      stimulus_done = 1;
   end
