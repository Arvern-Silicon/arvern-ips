//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_half_write
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_half_write
// Module Description : WRITING ONE HALF OF MTIME MUST LEAVE THE OTHER ALONE.
//
//                      MTIME_LO and MTIME_HI are separate 32-bit registers on a
//                      32-bit bus, so a write to one is a complete, legal
//                      transaction on its own. Internally both halves share one
//                      64-bit write shadow and one load request, and that is
//                      where the hazard lives: the un-written half of the shadow
//                      holds the last value SOFTWARE put there, which is not the
//                      live count.
//
//                      Two symptoms, needing different setups to become visible:
//
//                        1. HI-only write rewinds LO. The shadow's LO is
//                           whatever was last written; the counter has advanced
//                           since. Visible with no reset at all -- just let the
//                           counter run between the two writes.
//                        2. LO-only write clobbers HI. Needs the shadow's HI to
//                           differ from the live HI, which cannot happen by
//                           counting (HI moves once every 2^32 ticks). A warm
//                           hresetn_i does it: the shadow resets to 0 while the
//                           LF-resident counter keeps its value. That makes case
//                           2 asynchronous-timebase only -- under LF_SYNC_EN the
//                           counter shares hresetn_i and resets along with the
//                           shadow, so the two cannot be made to differ.
//
//                      The read path carries the same hazard, because a pending
//                      write steers reads onto the shadow. Case 2 also checks
//                      that a read of MTIME_HI during a LO-only write's crossing
//                      window reports the counter, not the reset shadow.
//----------------------------------------------------------------------------

reg [63:0] base;
reg [63:0] rb;
reg [31:0] hi_during;
integer    guard;

`define MTIME_LO_ADDR    32'h0040BFF8
`define MTIME_HI_ADDR    32'h0040BFFC
`define MTIMECMP_LO_ADDR 32'h00404000
`define MTIMECMP_HI_ADDR 32'h00404004

task read_mtime;
   output [63:0] val;
   begin
      ahb_read(1, MACHINE, `MTIME_LO_ADDR, 32'h00000000, 2, 0, OK);
      ahb_read(1, MACHINE, `MTIME_HI_ADDR, 32'h00000000, 2, 0, OK);
      val = tb_ahb_aclint.mtime_shadow_ahb_sim;
   end
endtask

// Wait for a just-issued write to reach the counter and become visible in the
// mirror. The rising wait is not optional: ahb_write returns while the data
// phase is still in flight, so polling only for wr_pending to FALL would find
// it still low and return at once -- which reads as "the write landed" when
// nothing has happened yet.
task wait_write_landed;
   begin
      guard = 0;
      while ((tb_ahb_aclint.dut.u_mtimer.wr_pending === 1'b0) &&
             (guard < `LF_CYCLES(2))) begin
         @(posedge free_clk);
         guard = guard + 1;
      end
      if (tb_ahb_aclint.dut.u_mtimer.wr_pending !== 1'b1) begin
         $display("ERROR: a write to MTIME never registered as pending %t ns", $time);
         error = error + 1;
      end
      guard = 0;
      while ((tb_ahb_aclint.dut.u_mtimer.wr_pending === 1'b1) &&
             (guard < `LF_CYCLES(40))) begin
         @(posedge free_clk);
         guard = guard + 1;
      end
      // ...plus time for the mirror to pick the loaded value back up.
      repeat(`LF_CYCLES(3)) @(posedge free_clk);
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(`LF_CYCLES(4)) @(posedge free_clk);

      // Park MTIMECMP out of reach throughout: MTIME is being thrown around and
      // a spurious MTIP would only clutter the log.
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'hFFFFFFFF, 2, OK);
      repeat(`LF_CYCLES(6)) @(posedge free_clk);

      $display(" ===============================================");
      $display("|   HALF WRITE : HI ONLY MUST NOT REWIND LO     |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `MTIME_HI_ADDR, 32'h00000055, 2, OK);
      ahb_write(1, MACHINE, `MTIME_LO_ADDR, 32'h10000000, 2, OK);
      wait_write_landed;

      // Let the counter run well past what was written, so a shadow-sourced LO
      // is unmistakably BEHIND rather than merely different.
      repeat(`LF_CYCLES(30)) @(posedge free_clk);
      read_mtime(base);
      $display("INFO:  MTIME after 30 LF ticks = 0x%h_%h %t ns",
               base[63:32], base[31:0], $time);

      if ((base[63:32] !== 32'h00000055) || (base[31:0] <= 32'h10000000)) begin
         $display("ERROR: setup failed -- MTIME is 0x%h_%h, expected 0x00000055_1000xxxx %t ns",
                  base[63:32], base[31:0], $time);
         error = error + 1;
      end

      // HI only. LO is not part of this transaction and must keep counting.
      ahb_write(1, MACHINE, `MTIME_HI_ADDR, 32'h00000077, 2, OK);
      wait_write_landed;
      read_mtime(rb);
      $display("INFO:  MTIME after the HI-only write = 0x%h_%h %t ns",
               rb[63:32], rb[31:0], $time);

      if (rb[63:32] !== 32'h00000077) begin
         $display("ERROR: HI-only write did not take -- HI = 0x%h, wrote 0x00000077 %t ns",
                  rb[63:32], $time);
         error = error + 1;
      end else begin
         $display("PASS:  HI-only write took effect %t ns", $time);
      end

      if (rb[31:0] < base[31:0]) begin
         $display("ERROR: HI-only write REWOUND LO -- 0x%h before, 0x%h after; the load applied the LO shadow %t ns",
                  base[31:0], rb[31:0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  LO kept counting across the HI-only write (+%0d ticks) %t ns",
                  (rb[31:0] - base[31:0]), $time);
      end

      if (LF_SYNC_EN != 0) begin
         $display("");
         $display("INFO:  skipping the LO-only case -- it needs the counter to survive a");
         $display("       warm hresetn_i, which only the asynchronous timebase does %t ns", $time);
      end
      else begin

         $display("");
         $display(" ===============================================");
         $display("|   HALF WRITE : LO ONLY MUST NOT CLOBBER HI    |");
         $display(" ===============================================");

         // A warm hresetn_i resets the write shadow to 0 while the LF-resident
         // counter keeps its value -- the only way to make the shadow's HI
         // differ from the live HI, since HI otherwise moves once every 2^32
         // ticks.
         @(posedge free_clk);
         hresetn = 1'b0;
         repeat(`LF_CYCLES(4)) @(posedge free_clk);
         hresetn = 1'b1;
         repeat(`LF_CYCLES(6)) @(posedge free_clk);

         read_mtime(base);
         $display("INFO:  MTIME after the warm reset = 0x%h_%h (shadow HI is now 0) %t ns",
                  base[63:32], base[31:0], $time);

         if (base[63:32] !== 32'h00000077) begin
            $display("ERROR: MTIME_HI did not survive the warm reset -- 0x%h; the rest of this check is meaningless %t ns",
                     base[63:32], $time);
            error = error + 1;
         end

         ahb_write(1, MACHINE, `MTIME_LO_ADDR, 32'h20000000, 2, OK);

         // Read while the write is still crossing. A pending write steers reads
         // onto the shadow, so this is where a whole-64-bit select reports the
         // reset shadow instead of the counter. It must be a FULL LO-then-HI
         // pair: MTIME_HI is served from the atomicity snapshot taken during the
         // MTIME_LO read, so a lone HI read returns whatever the previous pair
         // latched and would pass regardless.
         read_mtime(rb);
         hi_during = rb[63:32];
         if (hi_during !== 32'h00000077) begin
            $display("ERROR: read of MTIME_HI during a LO-only write returned 0x%h, expected 0x00000077 -- the read took the HI shadow %t ns",
                     hi_during, $time);
            error = error + 1;
         end else begin
            $display("PASS:  MTIME_HI reads the counter while a LO-only write is crossing %t ns", $time);
         end

         wait_write_landed;
         read_mtime(rb);
         $display("INFO:  MTIME after the LO-only write = 0x%h_%h %t ns",
                  rb[63:32], rb[31:0], $time);

         if (rb[63:32] !== 32'h00000077) begin
            $display("ERROR: LO-only write CLOBBERED HI -- 0x%h, expected 0x00000077; the load applied the HI shadow %t ns",
                     rb[63:32], $time);
            error = error + 1;
         end else begin
            $display("PASS:  HI untouched by the LO-only write %t ns", $time);
         end

         if ((rb[31:0] < 32'h20000000) || (rb[31:0] > 32'h20000000 + 32'd1000)) begin
            $display("ERROR: LO-only write did not take -- LO = 0x%h, wrote 0x20000000 %t ns",
                     rb[31:0], $time);
            error = error + 1;
         end else begin
            $display("PASS:  LO-only write took effect %t ns", $time);
         end

      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
