//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    default_subordinate_stress
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : default_subordinate_stress.v
// Module Description : Default-subordinate ERROR-response stress test.
//                      Covers patterns that the existing single-unmapped
//                      test in simple_rdwr.v does not:
//                         (a) Back-to-back unmapped APHs from one master.
//                         (b) Concurrent unmapped APHs from M0+M1+M2.
//                         (c) Unmapped APH while another master is in DPH
//                             of a legitimate access (arbitration + dflt
//                             decoder interaction).
//                         (d) Mapped APH immediately following an ERROR
//                             (default-sub returns cleanly to idle).
//
//                      Also tracks the default-subordinate's data_phase
//                      FSM states reached and reports the histogram at end.
//----------------------------------------------------------------------------

integer ii;

// Snoop the default-subordinate's data_phase FSM (state coverage).
// In FUSED the dflt subordinate is named differently; gate accordingly.
`ifdef FUSED
   // FUSED has both nx and x default subordinates; pick the NX one
   // (X side uses fused leaves, no traffic to default sub from M0).
   wire [1:0] dflt_dp = dut.ahb_default_subordinate_inst_nx.data_phase;
`else `ifdef HIPERF
   wire [1:0] dflt_dp = dut.ahb_default_subordinate_inst_nx.data_phase;
`else
   wire [1:0] dflt_dp = dut.ahb_default_subordinate_inst.data_phase;
`endif
`endif

reg saw_00, saw_01, saw_10, saw_11;
initial begin
   saw_00 = 0; saw_01 = 0; saw_10 = 0; saw_11 = 0;
end
always @(posedge free_clk) begin
   if (hresetn) begin
      case (dflt_dp)
         2'b00: saw_00 = 1;
         2'b01: saw_01 = 1;
         2'b10: saw_10 = 1;
         2'b11: saw_11 = 1;
      endcase
   end
end

// Unmapped address constants — pick three values that all fall outside
// every defined window in the address map (ROM/SRAM at 0x004000xx /
// 0x004010xx, peripherals at 0x004020xx / 0x004030xx).
`define UNMAPPED_A 32'h0080_0000
`define UNMAPPED_B 32'h00C0_0000
`define UNMAPPED_C 32'h0010_0000

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(10) @(posedge free_clk);

      // Seed mapped memories so the post-error mapped-access readback works.
      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
         rom_inst0.mem[tb_idx]  = 32'hCAFE0000 | tb_idx;
      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
         sram_inst0.mem[tb_idx] = 32'h00000000;

      // Reset peripherals
      @(negedge free_clk);
      force   ahb_periph_example_inst0.hresetn_i = 1'b0;
      force   ahb_periph_example_inst1.hresetn_i = 1'b0;
      @(negedge free_clk);
      release ahb_periph_example_inst0.hresetn_i;
      release ahb_periph_example_inst1.hresetn_i;

      repeat(10) @(posedge free_clk);

      //==================================================================
      // (a) Back-to-back unmapped APHs from M1 (M1/M2 visible on every
      //     variant; M0 is constrained on HIPERF/FUSED).
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  (a) M1: 5 back-to-back unmapped READs              |");
      $display(" =====================================================");
      for (ii = 0; ii < 5; ii = ii + 1) begin
         // check=0: read returns 0 from default sub regardless of expected_data
         ahb_read(1, 1, `UNMAPPED_A + (ii * 4), 32'h0, 2, 0);
      end

      repeat(5) @(posedge free_clk);

      //==================================================================
      // (b) Concurrent unmapped APHs from M0, M1, M2 (all 3 masters
      //     racing to the default subordinate at once)
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  (b) Concurrent unmapped from M0+M1+M2              |");
      $display(" =====================================================");
      fork
         ahb_read(0, 1, `UNMAPPED_A, 32'h0, 2, 0);
         ahb_read(1, 1, `UNMAPPED_B, 32'h0, 2, 0);
         ahb_read(2, 1, `UNMAPPED_C, 32'h0, 2, 0);
      join

      repeat(5) @(posedge free_clk);

      //==================================================================
      // (c) Mixed: M1 issues mapped access while M2 simultaneously
      //     issues unmapped (default-sub fires while a legit slave is
      //     also active — exercises the arbitration + decoder
      //     interaction).
      //     Uses M1 (not M0) for the write because in FUSED mode M0's
      //     Port A is read-only on the fused SRAM/ROM controllers.
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  (c) M1 mapped concurrent with M2 unmapped          |");
      $display(" =====================================================");
      fork
         // M1 issues a valid SRAM write
         ahb_write(1, 1, 32'h00401040, 32'hDEADBEEF, 2);
         // M2 issues an unmapped access at the same time
         ahb_read (2, 1, `UNMAPPED_A,  32'h0,       2, 0);
      join

      repeat(5) @(posedge free_clk);

      //==================================================================
      // (d) Mapped access immediately following an unmapped one —
      //     confirms the default-sub returns to idle cleanly
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  (d) Mapped READ right after unmapped               |");
      $display(" =====================================================");
      ahb_read(1, 1, `UNMAPPED_A,        32'h0,           2, 0);
      ahb_read(1, 1, 32'h00400040,       rom_inst0.mem[16], 2, 1);  // check=1
      ahb_read(1, 1, 32'h00401040,       32'hDEADBEEF,    2, 1);  // verify M1's write

      repeat(10) @(posedge free_clk);

      //==================================================================
      // State coverage report
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  Default-sub FSM state coverage (data_phase)        |");
      $display(" =====================================================");
      $display("  state 2'b00 (IDLE)        : %s", saw_00 ? "HIT" : "MISS");
      $display("  state 2'b01 (ERR cyc 1)   : %s", saw_01 ? "HIT" : "MISS");
      $display("  state 2'b10 (ERR cyc 2)   : %s", saw_10 ? "HIT" : "MISS");
      $display("  state 2'b11 (back-to-back): %s", saw_11 ? "HIT"
                : "MISS (not reachable from protocol-compliant masters; see notes)");

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      stimulus_done = 1;
   end
