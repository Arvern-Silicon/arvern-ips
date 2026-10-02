//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_reset_midtransfer
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_reset_midtransfer.v
// Module Description : hresetn_i ASSERTED IN THE MIDDLE OF A TRANSFER.
//
//                        ahb_aclint.md Resets: "either may be asserted alone,
//                        at any time"; hresetn_i alone: "in-flight AHB transfer
//                        | abandoned; firmware must re-issue", MTIMECMP
//                        "disarmed to all-ones", MSIP "cleared", MTIME
//                        "survives" (LF_SYNC_EN=0; "with LF_SYNC_EN=1 ... MTIME
//                        restarts from zero on a warm reset").
//
//                      (a) during the data phase of a write (MSIP[0]=1,
//                          MTIMECMP_HI[0]=0, and SETSSIP[0]=1 when
//                          SU_MODE_EN=1). The write must not land, before or
//                          after the release: MSIP/SSIP never pulse or set, and
//                          MTIMECMP reads all-ones.
//                      (b) during the first cycle of an ERROR response (S-mode
//                          write to MSIP[0], PRIV_CHECK_EN=1 only).
//                            ahb_aclint.md: "A denied access gets the AHB-Lite
//                            two-cycle ERROR (hreadyout_o=0 then 1, hresp_o=1
//                            for both)."
//                          After the release hresp is low, and a new denied
//                          access gets its own full two-cycle ERROR.
//                      (c) during an MTIME_LO read that is stalling.
//                            ahb_aclint.md Wait states: "MTIME_LO read while
//                            the mirror is untrustworthy | <= 2R"; "The mirror
//                            is untrustworthy only out of reset and once per
//                            osc-off deep-sleep exit".
//                          The stall is provoked by a warm reset and a read
//                          issued on the first cycle after it; the second
//                          reset lands inside that stall. A re-issued read
//                          must stall at most 2R and return MTIME: the
//                          value set before the resets plus accrued ticks at
//                          LF_SYNC_EN=0, a restarted small count at
//                          LF_SYNC_EN=1. The doc also says LF_SYNC_EN=1 has
//                          "no read mirror"; if no stall is seen there, (c)
//                          reports it and checks only the recovery.
//
//                      After every release: with the bus idle, hreadyout_o=1
//                      and hresp_o=0 for four cycles, the documented reset
//                      values read back, and a fresh access works. Resets are
//                      released at a free_clk negedge (synchronous to
//                      hclk_aon_i) and held 8 cycles (>= one hclk_aon_i edge,
//                      as ASYNC_RST_EN=0 requires).
//----------------------------------------------------------------------------

localparam [31:0] RM_MSIP     = 32'h00400000;
localparam [31:0] RM_CMP_LO   = 32'h00404000;
localparam [31:0] RM_CMP_HI   = 32'h00404004;
localparam [31:0] RM_MTIME_LO = 32'h0040BFF8;
localparam [31:0] RM_MTIME_HI = 32'h0040BFFC;
localparam [31:0] RM_SETSSIP  = 32'h0040C000;
localparam integer RM_LF_NS   = 2 * `ACLINT_LF_HALF_PERIOD;

reg         rm_watch;
integer     rm_msip_hi;
integer     rm_ssip_hi;
integer     rm_i;
integer     rm_w;
integer     rm_guard;
integer     rm_drift;
reg         rm_r1;
reg         rm_r2;
reg  [31:0] rm_lo;
reg  [31:0] rm_hi;
reg  [63:0] rm_before;
reg  [63:0] rm_v;
reg         rm_stalled;
time        rm_t0;

// irq_m_software_o[0] / irq_s_software_o[0] must never rise while watched.
initial begin
   rm_watch   = 1'b0;
   rm_msip_hi = 0;
   rm_ssip_hi = 0;
end

always @(negedge free_clk)
   if (rm_watch) begin
      if (irq_m_software[0] === 1'b1) rm_msip_hi = rm_msip_hi + 1;
      if (irq_s_software[0] === 1'b1) rm_ssip_hi = rm_ssip_hi + 1;
   end

task rm_xfer;
   input         wr;
   input  [31:0] addr;
   input  [31:0] wdata;
   input   [3:0] prot;
   input         smode;
   output        resp_p1;
   output        resp_end;
   output [31:0] rdata;
   output integer waits;
   begin
      haddr  = addr;
      htrans = 2'b10;
      hwrite = wr;
      hsize  = 3'b010;
      hprot  = prot;
      hsmode = smode;
      @(posedge free_clk);
      #1;
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hwrite = 1'b0;
      hprot  = 4'h0;
      hsmode = 1'b0;
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

// Drive only the address phase of a transfer; returns at posedge+1 with the
// bus idle and the data phase in progress.
task rm_addr_phase;
   input         wr;
   input  [31:0] addr;
   input  [31:0] wdata;
   input   [3:0] prot;
   input         smode;
   begin
      haddr  = addr;
      htrans = 2'b10;
      hwrite = wr;
      hsize  = 3'b010;
      hprot  = prot;
      hsmode = smode;
      @(posedge free_clk);
      #1;
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hwrite = 1'b0;
      hprot  = 4'h0;
      hsmode = 1'b0;
      hsize  = 3'b000;
      hwdata = wdata;
   end
endtask

task rm_pulse_reset;
   begin
      hresetn = 1'b0;
      repeat(8) @(negedge free_clk);
      hresetn = 1'b1;
   end
endtask

// Idle bus after a release: ready, no error, for four cycles.
task rm_check_idle_ready;
   input [40*8:0] tag;
   begin
      for (rm_i = 0; rm_i < 4; rm_i = rm_i + 1) begin
         @(negedge free_clk);
         if ((hreadyout !== 1'b1) || (hresp !== 1'b0)) begin
            $display("ERROR: %0s -- idle bus after reset shows hreadyout=%b hresp=%b %t ns",
                     tag, hreadyout, hresp, $time);
            error = error + 1;
         end
      end
   end
endtask

task rm_check_reset_values;
   begin
      ahb_read(1, MACHINE, RM_MSIP,   32'h00000000, 2, 1, OK);
      ahb_read(1, MACHINE, RM_CMP_LO, 32'hFFFFFFFF, 2, 1, OK);
      ahb_read(1, MACHINE, RM_CMP_HI, 32'hFFFFFFFF, 2, 1, OK);
      if (NUM_HARTS > 1) begin
         ahb_read(1, MACHINE, RM_MSIP   + 4*(NUM_HARTS-1), 32'h00000000, 2, 1, OK);
         ahb_read(1, MACHINE, RM_CMP_LO + 8*(NUM_HARTS-1), 32'hFFFFFFFF, 2, 1, OK);
         ahb_read(1, MACHINE, RM_CMP_HI + 8*(NUM_HARTS-1), 32'hFFFFFFFF, 2, 1, OK);
      end
   end
endtask

// A fresh access works: MSIP[0] set, read back, cleared.
task rm_fresh_access;
   input [40*8:0] tag;
   begin
      ahb_write(1, MACHINE, RM_MSIP, 32'h00000001, 2, OK);
      repeat(2) @(negedge free_clk);
      if (irq_m_software[0] !== 1'b1) begin
         $display("ERROR: %0s -- fresh MSIP write after reset did not take %t ns", tag, $time);
         error = error + 1;
      end
      ahb_read (1, MACHINE, RM_MSIP, 32'h00000001, 2, 1, OK);
      ahb_write(1, MACHINE, RM_MSIP, 32'h00000000, 2, OK);
      repeat(2) @(negedge free_clk);
      if (irq_m_software[0] !== 1'b0) begin
         $display("ERROR: %0s -- fresh MSIP clear after reset did not take %t ns", tag, $time);
         error = error + 1;
      end
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(`LF_CYCLES(5)) @(posedge free_clk);

      $display(" ===============================================");
      $display("|   RESET MID-TRANSFER : WRITE DATA PHASE       |");
      $display(" ===============================================");

      // MSIP[0] = 1 in its data phase.
      rm_msip_hi = 0;
      rm_ssip_hi = 0;
      rm_watch   = 1'b1;
      rm_addr_phase(1, RM_MSIP, 32'h00000001, 4'h2, 1'b0);
      hresetn = 1'b0;
      repeat(8) @(negedge free_clk);
      hresetn = 1'b1;
      rm_check_idle_ready("(a) MSIP");
      repeat(`LF_CYCLES(1)) @(negedge free_clk);
      rm_watch = 1'b0;
      if (rm_msip_hi != 0) begin
         $display("ERROR: (a) MSIP write abandoned by reset still set irq_m_software_o[0] for %0d cycle(s) %t ns",
                  rm_msip_hi, $time);
         error = error + 1;
      end else begin
         $display("PASS:  (a) MSIP write in its data phase abandoned by reset %t ns", $time);
      end
      rm_check_reset_values;

      // MTIMECMP_HI[0] = 0 in its data phase.
      rm_addr_phase(1, RM_CMP_HI, 32'h00000000, 4'h2, 1'b0);
      rm_pulse_reset;
      rm_check_idle_ready("(a) MTIMECMP");
      repeat(4) @(negedge free_clk);
      rm_check_reset_values;
      $display("PASS:  (a) MTIMECMP write in its data phase abandoned by reset (checked by read-back) %t ns", $time);

      // SETSSIP[0] = 1 in its data phase.
      if (SU_MODE_EN != 0) begin
         rm_msip_hi = 0;
         rm_ssip_hi = 0;
         rm_watch   = 1'b1;
         rm_addr_phase(1, RM_SETSSIP, 32'h00000001, 4'h2, 1'b0);
         rm_pulse_reset;
         rm_check_idle_ready("(a) SETSSIP");
         repeat(`LF_CYCLES(1)) @(negedge free_clk);
         rm_watch = 1'b0;
         if (rm_ssip_hi != 0) begin
            $display("ERROR: (a) SETSSIP write abandoned by reset still pulsed irq_s_software_o[0] (%0d cycle(s)) %t ns",
                     rm_ssip_hi, $time);
            error = error + 1;
         end else begin
            $display("PASS:  (a) SETSSIP write in its data phase abandoned by reset %t ns", $time);
         end
      end

      rm_fresh_access("(a)");

      $display("");
      $display(" ===============================================");
      $display("|   RESET MID-TRANSFER : ERROR FIRST CYCLE      |");
      $display(" ===============================================");

      if (PRIV_CHECK_EN == 0) begin
         $display("SKIP:  PRIV_CHECK_EN=0 -- no ERROR response to interrupt %t ns", $time);
      end else begin
         rm_msip_hi = 0;
         rm_watch   = 1'b1;
         rm_addr_phase(1, RM_MSIP, 32'h00000001, 4'h2, 1'b1);   // S-mode: denied
         @(negedge free_clk);
         if ((hresp !== 1'b1) || (hreadyout !== 1'b0)) begin
            $display("ERROR: (b) expected ERROR P1 (hresp=1 hreadyout=0), got %b/%b -- premise lost %t ns",
                     hresp, hreadyout, $time);
            error = error + 1;
         end
         rm_pulse_reset;
         rm_check_idle_ready("(b)");
         repeat(`LF_CYCLES(1)) @(negedge free_clk);
         rm_watch = 1'b0;
         if (rm_msip_hi != 0) begin
            $display("ERROR: (b) denied MSIP write landed across the reset %t ns", $time);
            error = error + 1;
         end
         rm_check_reset_values;

         // A new denied access gets its own full two-cycle ERROR.
         rm_xfer(0, RM_MSIP, 32'h0, 4'h2, 1'b1, rm_r1, rm_r2, rm_lo, rm_w);
         if ((rm_r1 !== 1'b1) || (rm_w != 1) || (rm_r2 !== 1'b1) || (rm_lo !== 32'h0)) begin
            $display("ERROR: (b) denied access after the reset: P1 hresp=%b, %0d wait(s), final hresp=%b, rdata=0x%h -- expected 1/1/1/0 %t ns",
                     rm_r1, rm_w, rm_r2, rm_lo, $time);
            error = error + 1;
         end else begin
            $display("PASS:  (b) ERROR interrupted by reset; the next denied access gets a clean two-cycle ERROR %t ns", $time);
         end
         rm_fresh_access("(b)");
      end

      $display("");
      $display(" ===============================================");
      $display("|   RESET MID-TRANSFER : STALLED MTIME READ     |");
      $display(" ===============================================");

      // A distinctive MTIME, landed on the counter before the resets.
      ahb_write(1, MACHINE, RM_MTIME_LO, 32'h00001000, 2, OK);
      ahb_write(1, MACHINE, RM_MTIME_HI, 32'h00000042, 2, OK);
      rm_guard = 0;
      while ((tb_ahb_aclint.dut.u_mtimer.wr_pending === 1'b1) && (rm_guard < `LF_CYCLES(40))) begin
         @(posedge free_clk);
         rm_guard = rm_guard + 1;
      end
      repeat(`LF_CYCLES(3)) @(posedge free_clk);
      rm_xfer(0, RM_MTIME_LO, 32'h0, 4'h2, 1'b0, rm_r1, rm_r2, rm_lo, rm_w);
      rm_xfer(0, RM_MTIME_HI, 32'h0, 4'h2, 1'b0, rm_r1, rm_r2, rm_hi, rm_w);
      rm_before = {rm_hi, rm_lo};
      rm_t0     = $time;
      $display("INFO:  MTIME before the resets = 0x%h_%h %t ns", rm_hi, rm_lo, $time);
      if (rm_hi !== 32'h00000042) begin
         $display("ERROR: (c) MTIME setup did not land (HI 0x%h) %t ns", rm_hi, $time);
         error = error + 1;
      end

      // Warm reset, then an MTIME_LO read on the first cycle after it.
      @(negedge free_clk);
      rm_pulse_reset;
      if (tb_ahb_aclint.dut.u_mtimer.mirror_valid !== 1'b0)
         $display("INFO:  (c) mirror_valid = %b right after the warm reset %t ns",
                  tb_ahb_aclint.dut.u_mtimer.mirror_valid, $time);
      rm_addr_phase(0, RM_MTIME_LO, 32'h0, 4'h2, 1'b0);
      @(negedge free_clk);
      rm_stalled = (hreadyout === 1'b0);
      if (rm_stalled) begin
         @(negedge free_clk);
         rm_stalled = (hreadyout === 1'b0);
      end

      if (!rm_stalled) begin
         if (LF_SYNC_EN != 0) begin
            $display("INFO:  (c) LF_SYNC_EN=1: no MTIME_LO stall out of reset (\"no read mirror\"); only the recovery is checked %t ns", $time);
         end else begin
            $display("ERROR: (c) MTIME_LO read right after a warm reset did not stall -- premise lost %t ns", $time);
            error = error + 1;
         end
         while (hreadyout !== 1'b1) @(negedge free_clk);
         @(posedge free_clk);
         #1;
      end else begin
         if (hresp !== 1'b0) begin
            $display("ERROR: (c) hresp=%b during the MTIME_LO stall %t ns", hresp, $time);
            error = error + 1;
         end
         // Reset lands inside the stall.
         rm_pulse_reset;
         $display("PASS:  (c) hresetn_i asserted during a stalled MTIME_LO read %t ns", $time);
      end

      rm_check_idle_ready("(c)");
      rm_check_reset_values;

      // Re-issued read: bounded stall, then MTIME.
      rm_xfer(0, RM_MTIME_LO, 32'h0, 4'h2, 1'b0, rm_r1, rm_r2, rm_lo, rm_w);
      if (rm_r2 !== 1'b0) begin
         $display("ERROR: (c) re-issued MTIME_LO read returned ERROR %t ns", $time);
         error = error + 1;
      end
      if (rm_w > `LF_CYCLES(2)) begin
         $display("ERROR: (c) re-issued MTIME_LO read stalled %0d cycles, bound 2R = %0d %t ns",
                  rm_w, `LF_CYCLES(2), $time);
         error = error + 1;
      end else begin
         $display("INFO:  (c) re-issued MTIME_LO read stalled %0d cycle(s) (bound %0d) %t ns", rm_w, `LF_CYCLES(2), $time);
      end
      rm_xfer(0, RM_MTIME_HI, 32'h0, 4'h2, 1'b0, rm_r1, rm_r2, rm_hi, rm_w);
      rm_v     = {rm_hi, rm_lo};
      rm_drift = (($time - rm_t0) / RM_LF_NS) + 2;

      if (LF_SYNC_EN == 0) begin
         if ((rm_v < rm_before) || ((rm_v - rm_before) > rm_drift)) begin
            $display("ERROR: (c) MTIME after the resets = 0x%h_%h, expected 0x%h_%h + [0..%0d] (it survives hresetn_i) %t ns",
                     rm_hi, rm_lo, rm_before[63:32], rm_before[31:0], rm_drift, $time);
            error = error + 1;
         end else begin
            $display("PASS:  (c) MTIME survived both resets and reads back 0x%h_%h %t ns", rm_hi, rm_lo, $time);
         end
      end else begin
         if (rm_v > rm_drift) begin
            $display("ERROR: (c) LF_SYNC_EN=1: MTIME 0x%h_%h did not restart from zero on the warm reset %t ns",
                     rm_hi, rm_lo, $time);
            error = error + 1;
         end else begin
            $display("PASS:  (c) LF_SYNC_EN=1: MTIME restarted from zero (0x%h) %t ns", rm_lo, $time);
         end
      end

      rm_fresh_access("(c)");

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
