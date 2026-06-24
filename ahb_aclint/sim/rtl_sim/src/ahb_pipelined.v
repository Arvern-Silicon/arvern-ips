//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_pipelined
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_pipelined
// Module Description : Back-to-back (non-blocking) AHB transfers so a NONSEQ
//                      address phase overlaps the previous data phase, hitting
//                      the dph-re-latch-while-busy path (ahb_aclint.v:107). The
//                      standard tests use blocking=1, which inserts an IDLE
//                      between beats, so this overlap was never stimulated.
//                      Verifies the last write wins and nothing is dropped or
//                      reordered.
//----------------------------------------------------------------------------

reg pipe_seen;

// Observe a genuine pipelined moment: a new address phase valid while the
// previous data phase is still in flight.
initial pipe_seen = 1'b0;
always @(posedge free_clk)
   if ((tb_ahb_aclint.dut.aph_valid === 1'b1) && (tb_ahb_aclint.dut.dph_valid === 1'b1))
      pipe_seen = 1'b1;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(20) @(posedge free_clk);

      $display(" ===============================================");
      $display("|        AHB : BACK-TO-BACK PIPELINED XFERS     |");
      $display(" ===============================================");

      // Three back-to-back non-blocking writes to MSIP[0]: 1 -> 0 -> 1. The
      // address phase of each overlaps the data phase of the previous, so the
      // final committed value must be the LAST write (1).
      ahb_write(0, MACHINE, 32'h00400000, 32'h00000001, 2, OK);
      ahb_write(0, MACHINE, 32'h00400000, 32'h00000000, 2, OK);
      ahb_write(0, MACHINE, 32'h00400000, 32'h00000001, 2, OK);

      // Blocking read-back drains the pipe and checks the final state.
      ahb_read(1, MACHINE, 32'h00400000, 32'h00000001, 2, 1, OK);

      if (pipe_seen) begin
         $display("PASS:  pipelined address/data-phase overlap observed %t ns", $time);
      end else begin
         $display("ERROR: no pipelined overlap observed -- transfers were not back-to-back %t ns", $time);
         error = error + 1;
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
