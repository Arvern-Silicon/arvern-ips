//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_mtip_mask
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_mtip_mask.v
// Module Description : NO TRAP STORM WHEN MTIMECMP IS REPROGRAMMED.
//
//                      The hazard is the canonical one: firmware takes an MTI,
//                      writes a future mtimecmp inside the handler, and MRETs.
//                      If MTIP is still asserted from the OLD compare when it
//                      returns, the trap re-fires immediately and the handler
//                      never makes progress.
//
//                      There is no suppression mask: irq_m_timer_o compares on
//                      the hclk side against stage 1 of MTIMECMP, which takes
//                      the write in the AHB write cycle itself, so MTIP reacts
//                      to a reprogram within one cycle and never reflects the
//                      old compare while the value crosses to the LF side.
//
//                      The test checks the PROPERTY rather than the
//                      mechanism: after a reprogram to a future deadline, MTIP
//                      must go low and STAY low. Any re-assertion before the new
//                      deadline -- however brief -- is the trap storm, whether
//                      it comes from a stale compare, a torn 64-bit update, or a
//                      partial load.
//----------------------------------------------------------------------------

integer    guard;
integer    glitches;
reg        watch_glitch;
reg        mtip_d;
reg [63:0] mt_now;
reg [63:0] mt_target;

`define MTIME_LO_ADDR    32'h0040BFF8
`define MTIME_HI_ADDR    32'h0040BFFC
`define MTIMECMP_LO_ADDR 32'h00404000
`define MTIMECMP_HI_ADDR 32'h00404004

// Any rising edge of MTIP while we are watching is a violation: the deadline is
// far in the future, so the only way it can re-assert is a transient.
initial
   begin
      glitches     = 0;
      watch_glitch = 1'b0;
      mtip_d       = 1'b0;
      forever begin
         // Mid-cycle sample: MTIP is combinational off registers clocked on the
         // free_clk rising edge, so a rising-edge sample can land between their updates.
         @(negedge free_clk);
         if (watch_glitch && (tb_ahb_aclint.dut.irq_m_timer_o[0] === 1'b1) && (mtip_d === 1'b0)) begin
            glitches = glitches + 1;
            $display("INFO:  spurious MTIP re-assertion after reprogram %t ns", $time);
         end
         mtip_d = tb_ahb_aclint.dut.irq_m_timer_o[0];
      end
   end

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(20) @(posedge free_clk);

      $display(" ===============================================");
      $display("|   MTIMER : NO TRAP STORM ON REPROGRAM         |");
      $display(" ===============================================");

      // Arm a deadline already in the past so MTIP is pending, exactly as it
      // would be on entry to the handler.
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, 32'h00000000, 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'h00000001, 2, OK);

      guard = 0;
      while ((tb_ahb_aclint.dut.irq_m_timer_o[0] !== 1'b1) && (guard < `LF_CYCLES(20))) begin
         @(posedge free_clk);
         guard = guard + 1;
      end

      if (tb_ahb_aclint.dut.irq_m_timer_o[0] !== 1'b1) begin
         $display("ERROR: MTIP never asserted for an already-expired deadline %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIP pending on an expired deadline %t ns", $time);
      end

      // Reprogram to a deadline far enough out that nothing legitimate can fire.
      // Written HI-then-LO, the documented order.
      mt_now    = tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_lf;
      mt_target = mt_now + 64'd100000;

      watch_glitch = 1'b1;
      mtip_d       = tb_ahb_aclint.dut.irq_m_timer_o[0];
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, mt_target[63:32], 2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, mt_target[31:0],  2, OK);

      // MTIP must drop once the new compare reaches the LF domain.
      guard = 0;
      while ((tb_ahb_aclint.dut.irq_m_timer_o[0] !== 1'b0) && (guard < `LF_CYCLES(20))) begin
         @(posedge free_clk);
         guard = guard + 1;
      end

      if (tb_ahb_aclint.dut.irq_m_timer_o[0] !== 1'b0) begin
         $display("ERROR: MTIP still asserted %0d cycles after reprogramming to a future deadline %t ns",
                  guard, $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIP cleared after reprogram (%0d cycles) %t ns", guard, $time);
      end

      // Now the real check: it must STAY low. Watch several LF periods -- long
      // enough for any partial load, torn update or stale-compare transient to
      // show itself, and still far short of the new deadline.
      repeat(`LF_CYCLES(12)) @(posedge free_clk);
      watch_glitch = 1'b0;

      if (glitches != 0) begin
         $display("ERROR: MTIP re-asserted %0d time(s) after reprogram -- trap storm %t ns", glitches, $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIP stayed low across the reprogram window (no trap storm) %t ns", $time);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
