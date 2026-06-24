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
// Module Description : Exercise the MTIMECMP write-busy AHB back-pressure path.
//                      A second write to the SAME MTIMECMP half while the
//                      first write's CDC handshake is still in flight must
//                      STALL the AHB bus (reg_ready_o -> hreadyout_o low,
//                      mtimecmp_write_stall asserted) until the first commits,
//                      then complete -- with the final value being the second
//                      write. Previously no test issued a second same-half
//                      write before the CDC settled, so this wait-state path
//                      and the busy-gated write_pulse were never stimulated.
//----------------------------------------------------------------------------

reg stall_observed;

// Latch any cycle in which the MTIMECMP write stall fires (drives hreadyout
// low). Sampled on free_clk because hclk_i may be gated between phases.
initial stall_observed = 1'b0;
always @(posedge free_clk)
   if (tb_ahb_aclint.dut.u_mtimer.mtimecmp_write_stall === 1'b1)
      stall_observed = 1'b1;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(20) @(posedge free_clk);

      $display(" ===============================================");
      $display("|     MTIMER : MTIMECMP WRITE-BUSY STALL        |");
      $display(" ===============================================");

      // First write to MTIMECMP_LO[0]. This fires write_lo_pulse and raises
      // write_lo_busy on the next edge; the CDC handshake then runs for many
      // cycles on the LF side.
      ahb_write(1, MACHINE, 32'h00404000, 32'h11111111, 2, OK);

      // Confirm the busy flag actually came up (otherwise the stall test below
      // would be vacuous).
      if (tb_ahb_aclint.dut.u_mtimer.write_lo_busy[0] !== 1'b1) begin
         $display("WARNING: write_lo_busy[0] not high right after first write -- CDC faster than expected %t ns", $time);
      end

      // Second write to the SAME half with NO settle gap. reg_ready_o must go
      // low (bus stalls) until the first handshake completes, then this value
      // commits. The blocking ahb_write naturally rides the wait states.
      ahb_write(1, MACHINE, 32'h00404000, 32'h22222222, 2, OK);

      if (stall_observed) begin
         $display("PASS:  MTIMECMP second same-half write stalled the bus (mtimecmp_write_stall seen) %t ns", $time);
      end else begin
         $display("ERROR: MTIMECMP second same-half write did NOT stall -- write-busy back-pressure missing %t ns", $time);
         error = error + 1;
      end

      // Let both CDC handshakes drain, then read back: the surviving value
      // must be the SECOND write (0x22222222), proving the stalled write
      // committed and was not dropped.
      repeat(80) @(posedge free_clk);
      ahb_read(1, MACHINE, 32'h00404000, 32'h22222222, 2, 1, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
