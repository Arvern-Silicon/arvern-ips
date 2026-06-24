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
// File Name          : mtimer_mtip_mask
// Module Description : Isolate the MTIP write-busy suppression mask. The output
//                      is irq_m_timer_o = irq_sync & ~mtimecmp_write_busy
//                      (aclint_mtimer.v:320): MTIP must be forced low for a
//                      hart while that hart's MTIMECMP write CDC is in flight,
//                      EVEN THOUGH the underlying synchronised comparator
//                      (irq_sync) is still asserted. No existing test
//                      distinguishes "MTIP low because masked" from "MTIP low
//                      because the compare value changed", so a dropped or
//                      stuck mask term would be invisible. Here the compare
//                      value is held matched (write the same value), so
//                      irq_sync stays high and the ONLY reason MTIP drops is
//                      the mask.
//----------------------------------------------------------------------------

reg mask_seen;
reg mask_violation;
integer guard;

// Continuous monitor (robust to exact CDC timing): whenever hart 0's MTIMECMP
// write is busy AND the synchronised comparator is still asserted, the masked
// output MUST be low. mask_seen records the mask working; mask_violation records
// any cycle the mask failed to suppress the output.
initial begin mask_seen = 1'b0; mask_violation = 1'b0; end
always @(negedge free_clk)
   if ((tb_ahb_aclint.dut.u_mtimer.write_lo_busy[0] === 1'b1) &&
       (tb_ahb_aclint.dut.u_mtimer.irq_sync[0]       === 1'b1)) begin
      if (tb_ahb_aclint.dut.irq_m_timer_o[0] === 1'b0) mask_seen      = 1'b1;
      if (tb_ahb_aclint.dut.irq_m_timer_o[0] === 1'b1) mask_violation = 1'b1;
   end

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(20) @(posedge free_clk);

      $display(" ===============================================");
      $display("|     MTIMER : MTIP WRITE-BUSY SUPPRESSION      |");
      $display(" ===============================================");

      // Program MTIMECMP[0] = 0 so the comparator is permanently matched
      // (mtime >= 0 always) -> irq_sync settles high and stays high.
      ahb_write(1, MACHINE, 32'h00404004, 32'h00000000, 2, OK);
      ahb_write(1, MACHINE, 32'h00404000, 32'h00000000, 2, OK);

      // Wait for the CDC + 2-FF sync so irq_m_timer_o[0] is solidly asserted.
      guard = 0;
      while ((tb_ahb_aclint.dut.irq_m_timer_o[0] !== 1'b1) && (guard < 400)) begin
         @(posedge free_clk);
         guard = guard + 1;
      end
      if (tb_ahb_aclint.dut.irq_m_timer_o[0] !== 1'b1) begin
         $display("ERROR: MTIP[0] never asserted during setup -- cannot test the mask %t ns", $time);
         error = error + 1;
      end else begin
         $display("INFO:  MTIP[0] asserted, irq_sync[0]=%b %t ns",
                  tb_ahb_aclint.dut.u_mtimer.irq_sync[0], $time);
      end

      // Now write the SAME MTIMECMP_LO value again. The compare result does not
      // change (irq_sync stays high), but write_lo_busy[0] goes high and must
      // mask irq_m_timer_o[0] low for the duration of the handshake. The
      // continuous monitor above captures the masked window regardless of the
      // exact cycle busy rises/falls.
      ahb_write(1, MACHINE, 32'h00404000, 32'h00000000, 2, OK);

      // Wait for the write CDC handshake to fully drain.
      guard = 0;
      while ((tb_ahb_aclint.dut.u_mtimer.write_lo_busy[0] === 1'b1) && (guard < 400)) begin
         @(posedge free_clk);
         guard = guard + 1;
      end
      repeat(4) @(negedge free_clk);   // let the monitor settle past the busy edge

      if (mask_violation) begin
         $display("ERROR: MTIP[0] NOT masked during write-busy (mask term dropped) %t ns", $time);
         error = error + 1;
      end
      if (mask_seen) begin
         $display("PASS:  MTIP[0] held low by write-busy mask while irq_sync stayed high %t ns", $time);
      end else begin
         $display("ERROR: never observed the write-busy mask suppressing MTIP[0] %t ns", $time);
         error = error + 1;
      end

      // After the handshake completes the mask releases and MTIP returns high
      // (compare value is unchanged and still matched).
      guard = 0;
      while ((tb_ahb_aclint.dut.irq_m_timer_o[0] !== 1'b1) && (guard < 400)) begin
         @(posedge free_clk);
         guard = guard + 1;
      end
      if (tb_ahb_aclint.dut.irq_m_timer_o[0] !== 1'b1) begin
         $display("ERROR: MTIP[0] did not return high after write-busy cleared %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIP[0] returned high after the mask released %t ns", $time);
      end

      // Cleanup.
      ahb_write(1, MACHINE, 32'h00404000, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, 32'h00404004, 32'hFFFFFFFF, 2, OK);
      repeat(40) @(posedge free_clk);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
