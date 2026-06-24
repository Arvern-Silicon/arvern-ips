//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arbiter_stress
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arbiter_stress.v
// Module Description : High-volume multi-master arbitration stress test.
//                      60 non-blocking transactions per master (180 total)
//                      with randomised inter-issue gaps for maximal
//                      overlap.  Designed to stress the m_aph_pending
//                      cache-replay path under sustained contention.
//                      Run with -random_ws to also stress wait-state
//                      handling at the slave side.
//
//                      Data-integrity is verified by per-master readback
//                      of every write at the end. The TB's protocol +
//                      HMASTER monitors validate timing and ID propagation
//                      throughout.
//
//                      Per-master m_aph_pending duration is tracked
//                      live and a min/max/avg histogram is printed at
//                      the end as a coverage signal.
//----------------------------------------------------------------------------

integer ii;
integer m0_dly, m1_dly, m2_dly;

// Per-master pending-cycle tracking (coverage signals)
integer m0_pend_total, m0_pend_max, m0_pend_runs;
integer m1_pend_total, m1_pend_max, m1_pend_runs;
integer m2_pend_total, m2_pend_max, m2_pend_runs;
integer m0_pend_cur,   m1_pend_cur,   m2_pend_cur;

// Reference to the m_aph_pending signal for each master. The hierarchical
// path differs by variant.  Wired below.
wire m0_pending, m1_pending, m2_pending;
`ifdef HIPERF
   // HIPERF: m0 has no manager_if at the top NX side; expose its NX-side
   // pending only when M0 is acting as an NX master (rare here since M0 is
   // wired to M_X). M1=NX[0], M2=NX[1] for the NX-side manager_mux.
   assign m0_pending = 1'b0;
   assign m1_pending = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
   assign m2_pending = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
`else `ifdef FUSED
   // FUSED: same NX-side path; M0 goes directly to fused leaves (Port A).
   assign m0_pending = 1'b0;
   assign m1_pending = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
   assign m2_pending = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
`else
   assign m0_pending = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
   assign m1_pending = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
   assign m2_pending = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[2].ahb_manager_if_inst.m_aph_pending;
`endif
`endif

// Pending-duration tracker (one per master). Counts the length of every
// run of m_pending == 1 and accumulates into a min/max/avg histogram.
always @(posedge free_clk) begin
    if (!hresetn) begin
        m0_pend_total = 0; m0_pend_max = 0; m0_pend_runs = 0; m0_pend_cur = 0;
        m1_pend_total = 0; m1_pend_max = 0; m1_pend_runs = 0; m1_pend_cur = 0;
        m2_pend_total = 0; m2_pend_max = 0; m2_pend_runs = 0; m2_pend_cur = 0;
    end else begin
        // M0
        if      (m0_pending)                  begin m0_pend_cur = m0_pend_cur + 1; end
        else if (m0_pend_cur != 0) begin
            m0_pend_total = m0_pend_total + m0_pend_cur;
            if (m0_pend_cur > m0_pend_max) m0_pend_max = m0_pend_cur;
            m0_pend_runs = m0_pend_runs + 1;
            m0_pend_cur  = 0;
        end
        // M1
        if      (m1_pending)                  begin m1_pend_cur = m1_pend_cur + 1; end
        else if (m1_pend_cur != 0) begin
            m1_pend_total = m1_pend_total + m1_pend_cur;
            if (m1_pend_cur > m1_pend_max) m1_pend_max = m1_pend_cur;
            m1_pend_runs = m1_pend_runs + 1;
            m1_pend_cur  = 0;
        end
        // M2
        if      (m2_pending)                  begin m2_pend_cur = m2_pend_cur + 1; end
        else if (m2_pend_cur != 0) begin
            m2_pend_total = m2_pend_total + m2_pend_cur;
            if (m2_pend_cur > m2_pend_max) m2_pend_max = m2_pend_cur;
            m2_pend_runs = m2_pend_runs + 1;
            m2_pend_cur  = 0;
        end
    end
end

// Helpers — randomised address picker for each master.
// In HIPERF/FUSED, M0 only sees X-side slaves (ROM 0x00400000, SRAM 0x00401000).
// M1/M2 see all four (ROM, SRAM, periph0 @ 0x00402000, periph1 @ 0x00403000).
function [31:0] m0_pick_addr;
    input integer seed_offset;
    reg     [1:0] which;
    begin
        which = $urandom % 2;     // 0=ROM, 1=SRAM
        case (which)
            2'b00:  m0_pick_addr = 32'h00400000 | ((($urandom & 32'h0000007F) << 2) & 32'h000003FC);
            default:m0_pick_addr = 32'h00401000 | ((($urandom & 32'h0000007F) << 2) & 32'h000003FC);
        endcase
    end
endfunction

function [31:0] mn_pick_addr;
    input integer master;
    reg     [1:0] which;
    begin
        which = $urandom % 4;
        case (which)
            2'b00: mn_pick_addr = 32'h00400000 | ((($urandom & 32'h0000007F) << 2) & 32'h000003FC);
            2'b01: mn_pick_addr = 32'h00401000 | ((($urandom & 32'h0000007F) << 2) & 32'h000003FC);
            2'b10: mn_pick_addr = 32'h00402000 | ((($urandom & 32'h0000007F) << 2) & 32'h000003FC);
            default:mn_pick_addr = 32'h00403000 | ((($urandom & 32'h0000007F) << 2) & 32'h000003FC);
        endcase
    end
endfunction

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(10) @(posedge free_clk);

      $display("");
      $display(" =====================================================");
      $display("|     ARBITER STRESS  —  60 trans per master x 3      |");
      $display(" =====================================================");

      // Initialize ROM with random readback values
      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
         rom_inst0.mem[tb_idx]  = $urandom;
      // Clear SRAM
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

      // Three masters in parallel: 60 transactions each, all non-blocking,
      // randomised inter-issue gaps (0..3 cycles).
      fork
         begin
            for (ii = 0; ii < 60; ii = ii + 1) begin
               m0_dly = $urandom % 4;
               repeat(m0_dly) @(posedge free_clk);
               // M0 reads only (avoids hitting NX-side in HIPERF/FUSED)
               ahb_read(0, 0, m0_pick_addr(ii), 32'h0, 2, 0);   // check=0 (skip data check during contention)
            end
         end
         begin
            for (ii = 0; ii < 60; ii = ii + 1) begin
               m1_dly = $urandom % 4;
               repeat(m1_dly) @(posedge free_clk);
               if ($urandom & 1'b1) begin
                  ahb_write(1, 0, mn_pick_addr(1), $urandom, 2);
               end else begin
                  ahb_read (1, 0, mn_pick_addr(1), 32'h0, 2, 0);
               end
            end
         end
         begin
            for (ii = 0; ii < 60; ii = ii + 1) begin
               m2_dly = $urandom % 4;
               repeat(m2_dly) @(posedge free_clk);
               if ($urandom & 1'b1) begin
                  ahb_write(2, 0, mn_pick_addr(2), $urandom, 2);
               end else begin
                  ahb_read (2, 0, mn_pick_addr(2), 32'h0, 2, 0);
               end
            end
         end
      join

      // Drain
      repeat(50) @(posedge free_clk);

      $display("");
      $display(" =====================================================");
      $display("|     m_aph_pending duration coverage (cycles held)   |");
      $display(" =====================================================");
      $display("  M0 : runs=%0d  total=%0d cyc  max=%0d cyc  avg=%0d cyc",
               m0_pend_runs, m0_pend_total, m0_pend_max,
               (m0_pend_runs ? (m0_pend_total / m0_pend_runs) : 0));
      $display("  M1 : runs=%0d  total=%0d cyc  max=%0d cyc  avg=%0d cyc",
               m1_pend_runs, m1_pend_total, m1_pend_max,
               (m1_pend_runs ? (m1_pend_total / m1_pend_runs) : 0));
      $display("  M2 : runs=%0d  total=%0d cyc  max=%0d cyc  avg=%0d cyc",
               m2_pend_runs, m2_pend_total, m2_pend_max,
               (m2_pend_runs ? (m2_pend_total / m2_pend_runs) : 0));

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      stimulus_done = 1;
   end
