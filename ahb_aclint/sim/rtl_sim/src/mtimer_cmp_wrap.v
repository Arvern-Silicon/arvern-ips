//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_cmp_wrap
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_cmp_wrap.v
// Module Description : MTIP AT THE COMPARE BOUNDARY AND ACROSS THE 2^64 WRAP.
//
//                      mtimer_cmp_boundary pins the exact LF edge, but it does
//                      so on the LF-domain wake flop and therefore skips
//                      entirely under LF_SYNC_EN=1. The interrupt firmware
//                      actually takes is irq_m_timer_o, which is generated on
//                      the AHB side from the stage-1 comparand and exists in
//                      BOTH timebase modes -- so it is checked here, with no
//                      skip.
//
//                      The wrap matters because the compare is a plain unsigned
//                      >= on a counter that rolls. MTIME is driven close to
//                      2^64 and allowed to roll through zero:
//                        - MTIP must assert once MTIME reaches the comparand;
//                        - after the roll MTIME is far BELOW the comparand
//                          again, so MTIP must fall.
//                      That is what "pending whenever mtime >= mtimecmp" means
//                      when the counter wraps: there is no sticky latch and no
//                      special-casing. Unreachable in the field at 32 kHz
//                      (~17 million years), which is exactly why it needs a
//                      test rather than an argument.
//----------------------------------------------------------------------------

integer    guard;
reg [63:0] mt_seed;
reg [63:0] mt_deadline;
reg [63:0] mt_at_fire;
reg        saw_fire;
reg        saw_wrap;

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

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(20) @(posedge free_clk);

      mt_seed     = 64'hFFFFFFFF_FFFFFFF0;
      mt_deadline = 64'hFFFFFFFF_FFFFFFF8;
      saw_fire    = 1'b0;
      saw_wrap    = 1'b0;

      $display(" ===============================================");
      $display("|   MTIMER : MTIP AT THE COMPARE BOUNDARY       |");
      $display(" ===============================================");

      // Park the deadline out of the way, then place MTIME just below 2^64.
      // LO then HI back to back is one load at the counter, so the seed lands
      // whole rather than as two halves.
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, `MTIME_LO_ADDR,    mt_seed[31:0],  2, OK);
      ahb_write(1, MACHINE, `MTIME_HI_ADDR,    mt_seed[63:32], 2, OK);

      repeat(`LF_CYCLES(3)) @(posedge free_clk);
      read_mtime(mt_at_fire);
      if (mt_at_fire[63:32] !== 32'hFFFFFFFF) begin
         $display("ERROR: MTIME seed did not land -- read 0x%h_%h %t ns",
                  mt_at_fire[63:32], mt_at_fire[31:0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIME seeded near the roll at 0x%h_%h %t ns",
                  mt_at_fire[63:32], mt_at_fire[31:0], $time);
      end

      // Arm the deadline a few ticks ahead, using the spec's RV32 store order.
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'hFFFFFFFF,       2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, mt_deadline[63:32], 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, mt_deadline[31:0],  2, OK);

      if (tb_ahb_aclint.dut.irq_m_timer_o[0] !== 1'b0) begin
         $display("ERROR: MTIP already set with MTIME below the deadline %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIP low below the deadline %t ns", $time);
      end

      // Let the counter reach the comparand.
      guard = 0;
      while ((saw_fire === 1'b0) && (guard < `LF_CYCLES(40))) begin
         @(posedge free_clk);
         if (tb_ahb_aclint.dut.irq_m_timer_o[0] === 1'b1) begin
            saw_fire   = 1'b1;
            mt_at_fire = tb_ahb_aclint.dut.u_mtimer.mtime_rd_src;
         end
         guard = guard + 1;
      end

      if (saw_fire !== 1'b1) begin
         $display("ERROR: MTIP never asserted before the roll %t ns", $time);
         error = error + 1;
      end else if (mt_at_fire !== mt_deadline) begin
         // Exact, not >=: firing one tick late would still satisfy a >= check,
         // so this is what distinguishes the spec's >= from a > .
         $display("ERROR: MTIP asserted at MTIME 0x%h_%h, not on the deadline 0x%h_%h %t ns",
                  mt_at_fire[63:32], mt_at_fire[31:0],
                  mt_deadline[63:32], mt_deadline[31:0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIP asserted exactly at MTIME == deadline 0x%h_%h (0x%h_%h) %t ns",
                  mt_at_fire[63:32], mt_at_fire[31:0],
                  mt_deadline[63:32], mt_deadline[31:0], $time);
      end

      $display("");
      $display(" ===============================================");
      $display("|   MTIMER : MTIP ACROSS THE 2^64 ROLL          |");
      $display(" ===============================================");

      // Ride the counter through zero. The comparand is still near 2^64, so on
      // the far side MTIME is below it again and the interrupt must release.
      guard = 0;
      while ((saw_wrap === 1'b0) && (guard < `LF_CYCLES(60))) begin
         @(posedge free_clk);
         if (tb_ahb_aclint.dut.u_mtimer.mtime_rd_src[63:32] === 32'h00000000)
            saw_wrap = 1'b1;
         guard = guard + 1;
      end

      if (saw_wrap !== 1'b1) begin
         $display("ERROR: MTIME never rolled through zero within the guard window %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIME rolled through zero (now 0x%h_%h) %t ns",
                  tb_ahb_aclint.dut.u_mtimer.mtime_rd_src[63:32],
                  tb_ahb_aclint.dut.u_mtimer.mtime_rd_src[31:0], $time);

         // Give the compare a tick to be reflected on the AHB side.
         repeat(`LF_CYCLES(2)) @(posedge free_clk);

         if (tb_ahb_aclint.dut.irq_m_timer_o[0] !== 1'b0) begin
            $display("ERROR: MTIP still asserted after the roll -- the compare is not a plain unsigned >= %t ns",
                     $time);
            error = error + 1;
         end else begin
            $display("PASS:  MTIP released after the roll (MTIME below the comparand again) %t ns", $time);
         end
      end

      // Leave the deadline disarmed so nothing fires during teardown.
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, 32'hFFFFFFFF, 2, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
