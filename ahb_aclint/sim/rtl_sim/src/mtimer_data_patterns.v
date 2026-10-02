//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_data_patterns
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_data_patterns.v
// Module Description : MTIME DATA PATTERNS THROUGH BOTH READ PATHS.
//
//                      Every bit of the 64-bit MTIME load, mirror and Zicntr
//                      snapshot toggled both ways, then checked through the AHB
//                      LO/HI pair AND the Zicntr time port:
//                        0xA5A5A5A5_5A5A5A5A, 0x5A5A5A5A_A5A5A5A5,
//                        0xFFFFFFF0_0000000F, then a LO-only write of
//                        0x00000008 (bit 3 alone set in LO; HI must keep
//                        0xFFFFFFF0), and all-zeros after the HI-only case
//                        below, so every bit also falls.
//                      Each value is checked only after the load has reached
//                      the counter (wr_pending seen high then low, plus
//                      three LF periods for the mirror, as mtimer_half_write
//                      waits):
//                        ahb_aclint.md Wait states: "a MTIME write reaches the
//                        counter two to three LF periods later (a quiet tick, a
//                        launch tick, then the LF edge that consumes it), with
//                        reads served from the pending value meanwhile."
//                        ahb_aclint.md MTIMER: "A write replaces the count on
//                        the LF edge it lands on rather than incrementing, so a
//                        read-back returns what was written plus whatever has
//                        since accrued."
//                        ahb_aclint.md rule 3: "A 64-bit write is atomic; a
//                        half-write touches only its own half. ... a
//                        back-to-back LO/HI pair reaches the counter as a single
//                        load ... Writing one half alone loads only that half;
//                        the other keeps counting, apart from holding still for
//                        the single LF edge the load consumes."
//                      Tolerance: the doc gives none numerically. A read must
//                      be >= the written value and at most (elapsed LF periods
//                      since the write + 2) above it; the Zicntr snapshot,
//                      taken after the AHB pair, must be >= it.
//
//                      Last, a Zicntr read granted while a HI-only MTIME write
//                      is still pending (wr_pending checked high at the grant):
//                      the snapshot must carry the new HI and the live LO --
//                      the pending value for the written half, the running
//                      count for the other (rule 3 plus the forwarding
//                      sentence above).
//                        ahb_aclint.md Wait states: "On the Zicntr port,
//                        time_req_i is a level held until granted; time_gnt_o
//                        is a one-cycle pulse with time_val_o valid alongside."
//----------------------------------------------------------------------------

localparam [31:0] DP_MTIME_LO  = 32'h0040BFF8;
localparam [31:0] DP_MTIME_HI  = 32'h0040BFFC;
localparam [31:0] DP_CMP_LO    = 32'h00404000;
localparam [31:0] DP_CMP_HI    = 32'h00404004;
localparam integer DP_LF_NS    = 2 * `ACLINT_LF_HALF_PERIOD;

reg  [63:0] dp_pat [0:2];
reg  [63:0] dp_exp;
reg  [63:0] dp_ahb;
reg  [63:0] dp_zic;
reg  [63:0] dp_base;
reg  [31:0] dp_lo;
reg  [31:0] dp_hi;
reg         dp_r1;
reg         dp_r2;
integer     dp_w;
integer     dp_i;
integer     dp_guard;
integer     dp_drift;
reg         dp_pend_at_gnt;
time        dp_t0;

task dp_xfer;
   input         wr;
   input  [31:0] addr;
   input  [31:0] wdata;
   output        resp_p1;
   output        resp_end;
   output [31:0] rdata;
   output integer waits;
   begin
      haddr  = addr;
      htrans = 2'b10;
      hwrite = wr;
      hsize  = 3'b010;
      hprot  = 4'h2;
      hsmode = 1'b0;
      @(posedge free_clk);
      #1;
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hwrite = 1'b0;
      hprot  = 4'h0;
      hsize  = 3'b000;
      hwdata = wdata;
      waits  = 0;
      @(negedge free_clk);
      resp_p1 = hresp;
      while ((hreadyout !== 1'b1) && (waits < `LF_CYCLES(4) + 16)) begin
         @(negedge free_clk);
         waits = waits + 1;
      end
      resp_end = hresp;
      rdata    = hrdata;
      @(posedge free_clk);
      #1;
   end
endtask

// 64-bit MTIME through the bus: LO (snapshots HI), then HI.
task dp_read_ahb;
   output [63:0] val;
   begin
      dp_xfer(0, DP_MTIME_LO, 32'h0, dp_r1, dp_r2, dp_lo, dp_w);
      if (dp_r2 !== 1'b0) begin
         $display("ERROR: MTIME_LO read returned ERROR %t ns", $time);
         error = error + 1;
      end
      dp_xfer(0, DP_MTIME_HI, 32'h0, dp_r1, dp_r2, dp_hi, dp_w);
      val = {dp_hi, dp_lo};
   end
endtask

// A write registers as pending and then retires; plus three LF periods for the
// mirror to show the loaded count.
task dp_wait_landed;
   begin
      dp_guard = 0;
      while ((tb_ahb_aclint.dut.u_mtimer.wr_pending === 1'b0) && (dp_guard < `LF_CYCLES(2))) begin
         @(posedge free_clk);
         dp_guard = dp_guard + 1;
      end
      if (tb_ahb_aclint.dut.u_mtimer.wr_pending !== 1'b1) begin
         $display("ERROR: MTIME write never registered as pending %t ns", $time);
         error = error + 1;
      end
      dp_guard = 0;
      while ((tb_ahb_aclint.dut.u_mtimer.wr_pending === 1'b1) && (dp_guard < `LF_CYCLES(40))) begin
         @(posedge free_clk);
         dp_guard = dp_guard + 1;
      end
      if (tb_ahb_aclint.dut.u_mtimer.wr_pending !== 1'b0) begin
         $display("ERROR: MTIME write still pending after 40 LF periods %t ns", $time);
         error = error + 1;
      end
      repeat(`LF_CYCLES(3)) @(posedge free_clk);
   end
endtask

// Check AHB and Zicntr views against a value written at time t_wr.
task dp_check;
   input [63:0]   expv;
   input time     t_wr;
   input [40*8:0] tag;
   begin
      dp_read_ahb(dp_ahb);
      dp_drift = (($time - t_wr) / DP_LF_NS) + 2;
      if ((dp_ahb < expv) || ((dp_ahb - expv) > dp_drift)) begin
         $display("ERROR: %0s -- AHB MTIME 0x%h_%h, expected 0x%h_%h + [0..%0d] %t ns",
                  tag, dp_ahb[63:32], dp_ahb[31:0], expv[63:32], expv[31:0], dp_drift, $time);
         error = error + 1;
      end else begin
         $display("PASS:  %0s -- AHB MTIME 0x%h_%h (+%0d) %t ns",
                  tag, dp_ahb[63:32], dp_ahb[31:0], (dp_ahb - expv), $time);
      end

      zicntr_time_read(dp_zic, tag);
      dp_drift = (($time - t_wr) / DP_LF_NS) + 2;
      if ((dp_zic < dp_ahb) || ((dp_zic - expv) > dp_drift)) begin
         $display("ERROR: %0s -- Zicntr time 0x%h_%h, expected >= AHB 0x%h_%h and <= 0x%h_%h + %0d %t ns",
                  tag, dp_zic[63:32], dp_zic[31:0], dp_ahb[63:32], dp_ahb[31:0],
                  expv[63:32], expv[31:0], dp_drift, $time);
         error = error + 1;
      end else begin
         $display("PASS:  %0s -- Zicntr time 0x%h_%h agrees %t ns", tag, dp_zic[63:32], dp_zic[31:0], $time);
      end
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(`LF_CYCLES(5)) @(posedge free_clk);

      dp_pat[0] = 64'hA5A5A5A5_5A5A5A5A;
      dp_pat[1] = 64'h5A5A5A5A_A5A5A5A5;
      dp_pat[2] = 64'hFFFFFFF0_0000000F;

      // Park MTIMECMP[0] so MTIP stays out of the way.
      ahb_write(1, MACHINE, DP_CMP_HI, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, DP_CMP_LO, 32'hFFFFFFFF, 2, OK);
      repeat(`LF_CYCLES(3)) @(posedge free_clk);

      $display(" ===============================================");
      $display("|   MTIME : 64-BIT DATA PATTERNS                |");
      $display(" ===============================================");

      for (dp_i = 0; dp_i < 3; dp_i = dp_i + 1) begin
         dp_t0 = $time;
         ahb_write(1, MACHINE, DP_MTIME_LO, dp_pat[dp_i][31:0],  2, OK);
         ahb_write(1, MACHINE, DP_MTIME_HI, dp_pat[dp_i][63:32], 2, OK);
         dp_wait_landed;
         dp_check(dp_pat[dp_i], dp_t0, "64-bit pattern");
      end

      $display("");
      $display(" ===============================================");
      $display("|   MTIME : LO-ONLY WRITE, BIT 3                |");
      $display(" ===============================================");

      // HI is 0xFFFFFFF0 and LO is a few ticks above 0xF: no carry can reach HI
      // in this test, so HI must still read 0xFFFFFFF0.
      dp_t0 = $time;
      ahb_write(1, MACHINE, DP_MTIME_LO, 32'h00000008, 2, OK);
      dp_wait_landed;
      dp_check(64'hFFFFFFF0_00000008, dp_t0, "LO-only 0x8");

      $display("");
      $display(" ===============================================");
      $display("|   MTIME : ZICNTR READ DURING A HI-ONLY WRITE  |");
      $display(" ===============================================");

      // Let the live LO run well clear of the LO shadow (0x8), so a snapshot
      // taking the shadow LO is unmistakable.
      repeat(`LF_CYCLES(30)) @(posedge free_clk);
      dp_read_ahb(dp_base);
      dp_t0 = $time;
      $display("INFO:  MTIME before the HI-only write = 0x%h_%h %t ns", dp_base[63:32], dp_base[31:0], $time);
      if (dp_base[31:0] < 32'h00000010) begin
         $display("ERROR: live LO did not advance past the shadow LO -- premise lost %t ns", $time);
         error = error + 1;
      end

      ahb_write(1, MACHINE, DP_MTIME_HI, 32'h00001234, 2, OK);
      zicntr_time_read(dp_zic, "during HI-only write");
      dp_pend_at_gnt = tb_ahb_aclint.dut.u_mtimer.wr_pending;
      dp_drift       = (($time - dp_t0) / DP_LF_NS) + 2;

      if (dp_pend_at_gnt !== 1'b1) begin
         $display("ERROR: HI-only write no longer pending at the grant -- the check below proves nothing %t ns", $time);
         error = error + 1;
      end
      if (dp_zic[63:32] !== 32'h00001234) begin
         $display("ERROR: Zicntr HI = 0x%h during a pending HI-only write, expected the pending 0x00001234 %t ns",
                  dp_zic[63:32], $time);
         error = error + 1;
      end else begin
         $display("PASS:  Zicntr HI is the pending write value %t ns", $time);
      end
      if ((dp_zic[31:0] < dp_base[31:0]) || ((dp_zic[31:0] - dp_base[31:0]) > dp_drift)) begin
         $display("ERROR: Zicntr LO = 0x%h during a pending HI-only write, expected the live count 0x%h + [0..%0d] %t ns",
                  dp_zic[31:0], dp_base[31:0], dp_drift, $time);
         error = error + 1;
      end else begin
         $display("PASS:  Zicntr LO is the live count, not the LO shadow %t ns", $time);
      end

      dp_wait_landed;
      dp_check({32'h00001234, dp_base[31:0]}, dp_t0, "after HI-only load");

      // All-zeros last: every bit the patterns above leave at 1 falls, through the
      // load, the mirror and the Zicntr snapshot.
      dp_t0 = $time;
      ahb_write(1, MACHINE, DP_MTIME_LO, 32'h00000000, 2, OK);
      ahb_write(1, MACHINE, DP_MTIME_HI, 32'h00000000, 2, OK);
      dp_wait_landed;
      dp_check(64'h0, dp_t0, "64-bit all-zeros");

      // Leave MTIMECMP disarmed.
      ahb_write(1, MACHINE, DP_CMP_HI, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, DP_CMP_LO, 32'hFFFFFFFF, 2, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
