//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_scan_mode
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_scan_mode.v
// Module Description : scan_mode_i ENTERED FROM FUNCTIONAL OPERATION, THEN LEFT
//                      THROUGH THE DOCUMENTED RESET.
//
//                      1. scan_mode=1 while running. The tick input is
//                         isolated, so no tick fires and the MTIME the bus and
//                         the Zicntr port see (the mirror, refreshed only on a
//                         tick) is frozen across six LF periods.
//                           ahb_aclint.md DFT: scan_mode_i "isolates the one
//                           place a clock is deliberately used as data
//                           (clk_lf_i into the tick synchroniser)".
//                           ahb_aclint.md Reads: "mtime_mirror is a 64-bit
//                           hclk_aon_i copy refreshed on every tick."
//                         Checked as: lf_tick never pulses, and AHB MTIME and
//                         Zicntr time are unchanged. Two LF periods of settling
//                         after the scan_mode edge are not checked.
//                         No MTIME or MTIMECMP write is issued in scan mode:
//                         with no tick, nothing written would ever cross.
//                      2. hresetn_i asserted in scan mode clears the trust
//                         state and the registers.
//                           ahb_aclint.md DFT: it "takes hclk_aon_en_i out of
//                           the trust-reset path, so that reset is controllable
//                           from hresetn_i alone in test".
//                           ahb_aclint.md: "hclk_aon_en_i therefore drives the
//                           reset of the two flops that vouch for tick-derived
//                           state: mirror_valid and the tick warm-up counter."
//                           ahb_aclint.md Resets: hresetn_i alone -> MTIMECMP
//                           "disarmed to all-ones", MSIP "cleared".
//                         Checked as: mirror_valid low during the reset, MSIP
//                         (set before) reads 0 and MTIMECMP reads all-ones
//                         after. MTIME is not read after this reset while
//                         scan_mode is still high: "an MTIME_LO read or csrr
//                         time issued before the first [LF edge revalidating
//                         the mirror] stalls without bound".
//                      3. scan_mode=0 with both resets high, then the
//                         documented reset, LF domain released first.
//                           ahb_aclint.md DFT: "Leaving scan mode does not
//                           restore functional state: apply hresetn_i (and
//                           resetn_lf_i) after scan_mode_i falls."
//                           ahb_aclint.md Resets: "release resetn_lf_i before
//                           hresetn_i"; ASYNC_RST_EN=0 resetn_lf_i "at least
//                           two clk_lf_i rising edges".
//                         Checked as: MTIME restarts from 0 (resetn_lf_i resets
//                         it at LF_SYNC_EN=0, hresetn_i at LF_SYNC_EN=1), counts
//                         again, Zicntr is granted, and an armed MTIMECMP raises
//                         MTIP.
//                           ahb_aclint.md Resets table: MTIME "reset to 0" by
//                           resetn_lf_i; "with LF_SYNC_EN=1 ... MTIME restarts
//                           from zero on a warm reset".
//                      No skip: the tick isolation exists in both LF_SYNC_EN
//                      modes (the tick is derived from clk_lf_i in both).
//----------------------------------------------------------------------------

localparam [31:0] SM_MSIP     = 32'h00400000;
localparam [31:0] SM_MTIME_LO = 32'h0040BFF8;
localparam [31:0] SM_MTIME_HI = 32'h0040BFFC;
localparam [31:0] SM_CMP_LO   = 32'h00404000;
localparam [31:0] SM_CMP_HI   = 32'h00404004;
localparam integer SM_LF_NS   = 2 * `ACLINT_LF_HALF_PERIOD;

reg  [63:0] sm_ref;
reg  [63:0] sm_zref;
reg  [63:0] sm_v;
reg  [63:0] sm_z;
reg  [63:0] sm_v1;
reg  [63:0] sm_tgt;
integer     sm_ticks;
reg         sm_count_ticks;
integer     sm_guard;
integer     sm_bound;
reg         sm_seen;
time        sm_t_rel;

initial begin
   sm_ticks       = 0;
   sm_count_ticks = 1'b0;
end

always @(negedge free_clk)
   if (sm_count_ticks && (tb_ahb_aclint.dut.u_mtimer.lf_tick === 1'b1))
      sm_ticks = sm_ticks + 1;

task sm_read_mtime;
   output [63:0] val;
   begin
      ahb_read(1, MACHINE, SM_MTIME_LO, 32'h00000000, 2, 0, OK);
      ahb_read(1, MACHINE, SM_MTIME_HI, 32'h00000000, 2, 0, OK);
      val = tb_ahb_aclint.mtime_shadow_ahb_sim;
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(`LF_CYCLES(5)) @(posedge free_clk);

      // Functional baseline, and nothing left crossing before scan entry.
      ahb_write(1, MACHINE, SM_CMP_HI, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, SM_CMP_LO, 32'hFFFFFFFF, 2, OK);
      repeat(`LF_CYCLES(4)) @(posedge free_clk);
      sm_read_mtime(sm_v);
      repeat(`LF_CYCLES(3)) @(posedge free_clk);
      sm_read_mtime(sm_v1);
      if (sm_v1 <= sm_v) begin
         $display("ERROR: MTIME not counting before scan entry (0x%h then 0x%h) %t ns", sm_v, sm_v1, $time);
         error = error + 1;
      end

      $display(" ===============================================");
      $display("|   SCAN MODE : NO TICK, MTIME FROZEN           |");
      $display(" ===============================================");

      @(negedge free_clk);
      scan_mode = 1'b1;
      repeat(`LF_CYCLES(2)) @(posedge free_clk);

      sm_read_mtime(sm_ref);
      zicntr_time_read(sm_zref, "scan reference");
      $display("INFO:  MTIME in scan mode = 0x%h_%h, Zicntr 0x%h_%h %t ns",
               sm_ref[63:32], sm_ref[31:0], sm_zref[63:32], sm_zref[31:0], $time);
      if (sm_zref !== sm_ref) begin
         $display("ERROR: Zicntr time 0x%h differs from the AHB MTIME 0x%h with no tick in between %t ns",
                  sm_zref, sm_ref, $time);
         error = error + 1;
      end

      sm_ticks       = 0;
      sm_count_ticks = 1'b1;
      repeat(`LF_CYCLES(6)) @(posedge free_clk);
      sm_count_ticks = 1'b0;

      sm_read_mtime(sm_v);
      zicntr_time_read(sm_z, "scan after 6 LF");
      if (sm_ticks != 0) begin
         $display("ERROR: %0d lf_tick pulse(s) in scan mode -- clk_lf_i is not isolated %t ns", sm_ticks, $time);
         error = error + 1;
      end else begin
         $display("PASS:  no lf_tick across six LF periods in scan mode %t ns", $time);
      end
      if ((sm_v !== sm_ref) || (sm_z !== sm_ref)) begin
         $display("ERROR: MTIME moved in scan mode -- ref 0x%h, AHB 0x%h, Zicntr 0x%h %t ns",
                  sm_ref, sm_v, sm_z, $time);
         error = error + 1;
      end else begin
         $display("PASS:  AHB and Zicntr MTIME frozen in scan mode %t ns", $time);
      end

      $display("");
      $display(" ===============================================");
      $display("|   SCAN MODE : hresetn ALONE RESETS THE TRUST  |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, SM_MSIP, 32'h00000001, 2, OK);
      repeat(2) @(negedge free_clk);
      if (irq_m_software[0] !== 1'b1) begin
         $display("ERROR: MSIP write in scan mode did not take -- premise lost %t ns", $time);
         error = error + 1;
      end

      @(negedge free_clk);
      hresetn = 1'b0;
      repeat(4) @(negedge free_clk);
      // LF_SYNC_EN=1 has no read mirror (ahb_aclint.md): nothing to drop.
      if (LF_SYNC_EN != 0)
         $display("INFO:  LF_SYNC_EN=1 -- no read mirror, mirror_valid check not applicable %t ns", $time);
      else if (tb_ahb_aclint.dut.u_mtimer.mirror_valid !== 1'b0) begin
         $display("ERROR: mirror_valid = %b with hresetn_i asserted in scan mode -- trust reset not controlled by hresetn_i %t ns",
                  tb_ahb_aclint.dut.u_mtimer.mirror_valid, $time);
         error = error + 1;
      end else begin
         $display("PASS:  hresetn_i alone drops mirror_valid in scan mode %t ns", $time);
      end
      if (irq_m_software[0] !== 1'b0) begin
         $display("ERROR: irq_m_software_o[0] still set under hresetn_i in scan mode %t ns", $time);
         error = error + 1;
      end
      repeat(4) @(negedge free_clk);
      hresetn = 1'b1;
      repeat(4) @(posedge free_clk);

      ahb_read(1, MACHINE, SM_MSIP,   32'h00000000, 2, 1, OK);
      ahb_read(1, MACHINE, SM_CMP_LO, 32'hFFFFFFFF, 2, 1, OK);
      ahb_read(1, MACHINE, SM_CMP_HI, 32'hFFFFFFFF, 2, 1, OK);

      $display("");
      $display(" ===============================================");
      $display("|   SCAN MODE : LEAVE, RESET, RESUME            |");
      $display(" ===============================================");

      @(negedge free_clk);
      scan_mode = 1'b0;
      repeat(4) @(negedge free_clk);

      hresetn   = 1'b0;
      resetn_lf = 1'b0;
      // >= two clk_lf rising edges for ASYNC_RST_EN=0, and hclk edges throughout.
      repeat(`LF_CYCLES(3)) @(posedge free_clk);
      @(negedge clk_lf);
      resetn_lf = 1'b1;
      sm_t_rel  = $time;
      repeat(4) @(negedge free_clk);
      hresetn   = 1'b1;

      // First MTIME_LO read waits for the mirror to revalidate.
      repeat(`LF_CYCLES(5)) @(posedge free_clk);
      sm_read_mtime(sm_v);
      sm_bound = (($time - sm_t_rel) / SM_LF_NS) + 2;
      $display("INFO:  MTIME after the post-scan reset = 0x%h_%h (bound %0d) %t ns",
               sm_v[63:32], sm_v[31:0], sm_bound, $time);
      if (sm_v > sm_bound) begin
         $display("ERROR: MTIME did not restart from 0 after the post-scan reset -- 0x%h_%h %t ns",
                  sm_v[63:32], sm_v[31:0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIME restarted from 0 after the post-scan reset %t ns", $time);
      end

      repeat(`LF_CYCLES(6)) @(posedge free_clk);
      sm_read_mtime(sm_v1);
      if (sm_v1 < sm_v + 3) begin
         $display("ERROR: MTIME not counting after leaving scan mode (0x%h then 0x%h) %t ns", sm_v, sm_v1, $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIME counts again after leaving scan mode (+%0d) %t ns", (sm_v1 - sm_v), $time);
      end

      zicntr_time_read(sm_z, "after scan exit");
      if (sm_z < sm_v1) begin
         $display("ERROR: Zicntr time 0x%h below the earlier AHB MTIME 0x%h %t ns", sm_z, sm_v1, $time);
         error = error + 1;
      end

      // A timer interrupt still works.
      sm_tgt = sm_v1 + 64'd10;
      ahb_write(1, MACHINE, SM_CMP_LO, 32'hFFFFFFFF,   2, OK);
      ahb_write(1, MACHINE, SM_CMP_HI, sm_tgt[63:32], 2, OK);
      ahb_write(1, MACHINE, SM_CMP_LO, sm_tgt[31:0],  2, OK);
      @(negedge free_clk);
      if (irq_m_timer[0] !== 1'b0) begin
         $display("ERROR: MTIP already set before the deadline %t ns", $time);
         error = error + 1;
      end
      sm_seen  = 1'b0;
      sm_guard = 0;
      while ((sm_seen == 1'b0) && (sm_guard < `LF_CYCLES(30))) begin
         @(negedge free_clk);
         sm_guard = sm_guard + 1;
         if (irq_m_timer[0] === 1'b1) sm_seen = 1'b1;
      end
      if (!sm_seen) begin
         $display("ERROR: MTIP never asserted after leaving scan mode %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIP asserts after leaving scan mode %t ns", $time);
      end

      ahb_write(1, MACHINE, SM_CMP_HI, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, SM_CMP_LO, 32'hFFFFFFFF, 2, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
