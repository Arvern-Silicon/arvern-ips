//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    cover_monitor (ahb_aclint tb include)
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : cover_monitor.v
// Module Description : Homegrown functional-coverage monitor (no SVA), always
//                      `included into tb_ahb_aclint. Each bin is a sticky flag
//                      raised the first time its condition is observed. At
//                      end-of-sim cover_report emits one machine-greppable
//                      "COVERAGE HIT: <bin>" line per raised bin; the sweep
//                      runner (run_sweep.py) unions these across all configs
//                      and FAILS the regression if any mandatory bin
//                      (sim_configs.MANDATORY_COVER_BINS) was never hit in any
//                      config. That suite-level gate is what makes an
//                      unexercised FSM state / interface visible -- the exact
//                      blind spot that hid the time_gnt_r clock-gate bug.
//
//                      Bins are set with '=== 1'b1' style compares so an X
//                      during reset can never raise a bin (no reset gating
//                      needed). All sampling is on the ungated free_clk.
//----------------------------------------------------------------------------

// ---- FSM ownership states (aclint_mtimer arbitration FSM) ----
reg cov_fsm_idle;
reg cov_fsm_ahb_pend;
reg cov_fsm_time_pend;
// ---- Zicntr side-band handshake ----
reg cov_time_req;
reg cov_time_gnt;
// ---- MTIMECMP write CDC ----
reg cov_wlo_busy;
reg cov_whi_busy;
reg cov_wr_stall;
// ---- Clock gate exercised in BOTH directions ----
reg cov_hclk_en_hi;
reg cov_hclk_en_lo;
// ---- Interrupt outputs ----
reg cov_irq_msw;
reg cov_irq_mtip;
reg cov_irq_ssw;
reg cov_wake_lf;
// ---- AHB protocol corners ----
reg cov_hresp_err;
reg cov_pipelined;
reg cov_wait_state;
reg cov_htrans_seq;
reg cov_htrans_busy;
reg cov_subword;
// ---- Top hart exercised (per-hart muxing at the high index) ----
reg cov_mtip_top_hart;
// ---- MTIP write-busy suppression mask actually engaged ----
reg cov_mtip_masked;

initial begin
   cov_fsm_idle      = 1'b0; cov_fsm_ahb_pend = 1'b0; cov_fsm_time_pend = 1'b0;
   cov_time_req      = 1'b0; cov_time_gnt     = 1'b0;
   cov_wlo_busy      = 1'b0; cov_whi_busy     = 1'b0; cov_wr_stall      = 1'b0;
   cov_hclk_en_hi    = 1'b0; cov_hclk_en_lo   = 1'b0;
   cov_irq_msw       = 1'b0; cov_irq_mtip     = 1'b0; cov_irq_ssw       = 1'b0;
   cov_wake_lf       = 1'b0;
   cov_hresp_err     = 1'b0; cov_pipelined    = 1'b0; cov_wait_state    = 1'b0;
   cov_htrans_seq    = 1'b0; cov_htrans_busy  = 1'b0; cov_subword       = 1'b0;
   cov_mtip_top_hart = 1'b0;
   cov_mtip_masked   = 1'b0;
end

always @(negedge free_clk) begin
   // FSM ownership states.
   if (tb_ahb_aclint.dut.u_mtimer.fsm_state === 2'b00) cov_fsm_idle      = 1'b1;
   if (tb_ahb_aclint.dut.u_mtimer.fsm_state === 2'b01) cov_fsm_ahb_pend  = 1'b1;
   if (tb_ahb_aclint.dut.u_mtimer.fsm_state === 2'b10) cov_fsm_time_pend = 1'b1;

   // Zicntr handshake.
   if (time_req === 1'b1) cov_time_req = 1'b1;
   if (time_gnt === 1'b1) cov_time_gnt = 1'b1;

   // MTIMECMP write CDC handshake + the resulting AHB stall.
   if (|tb_ahb_aclint.dut.u_mtimer.write_lo_busy === 1'b1) cov_wlo_busy = 1'b1;
   if (|tb_ahb_aclint.dut.u_mtimer.write_hi_busy === 1'b1) cov_whi_busy = 1'b1;
   if (tb_ahb_aclint.dut.u_mtimer.mtimecmp_write_stall === 1'b1) cov_wr_stall = 1'b1;

   // Clock-gate advisory toggles both ways.
   if (hclk_en === 1'b1) cov_hclk_en_hi = 1'b1;
   if (hclk_en === 1'b0) cov_hclk_en_lo = 1'b1;

   // Interrupt outputs.
   if (|irq_m_software === 1'b1) cov_irq_msw  = 1'b1;
   if (|irq_m_timer    === 1'b1) cov_irq_mtip = 1'b1;
   if (|irq_s_software === 1'b1) cov_irq_ssw  = 1'b1;
   if (|mtimer_wake_lf === 1'b1) cov_wake_lf  = 1'b1;
   // Only meaningful at a high hart count: at NUM_HARTS=1 the "top hart" is
   // hart 0 (trivially hit). Static parameter guard keeps it a real probe of
   // upper-index per-hart muxing (exercised by mtimer_multihart at nh16).
   if ((NUM_HARTS >= 16) && (irq_m_timer[NUM_HARTS-1] === 1'b1)) cov_mtip_top_hart = 1'b1;

   // AHB protocol corners.
   if (hresp === 1'b1) cov_hresp_err = 1'b1;
   if ((tb_ahb_aclint.dut.aph_valid === 1'b1) &&
       (tb_ahb_aclint.dut.dph_valid === 1'b1)) cov_pipelined = 1'b1;
   if ((tb_ahb_aclint.dut.dph_valid === 1'b1) && (hready === 1'b0)) cov_wait_state = 1'b1;
   if (htrans === 2'b11) cov_htrans_seq  = 1'b1;
   if (htrans === 2'b01) cov_htrans_busy = 1'b1;
   if ((tb_ahb_aclint.dut.aph_valid === 1'b1) && (hsize !== 3'b010)) cov_subword = 1'b1;

   // MTIP suppression mask engaged: comparator synced high AND that hart's
   // MTIMECMP write is busy AND the masked output is low.
   if (|(tb_ahb_aclint.dut.u_mtimer.irq_sync &
         tb_ahb_aclint.dut.u_mtimer.mtimecmp_write_busy &
         ~irq_m_timer) === 1'b1) cov_mtip_masked = 1'b1;
end

//----------------------------------------------------------------------------
// End-of-sim emit (called from tb_extra_report). One line per HIT bin; the
// runner greps "COVERAGE HIT:" across all per-config logs.
//----------------------------------------------------------------------------
task cover_emit;
   input [16*8:0] name;
   input          hit;
   begin
      if (hit) $display("COVERAGE HIT: %s", name);
      else     $display("COVERAGE MISS(local): %s", name);
   end
endtask

task cover_report;
   begin
      $display("---------------- FUNCTIONAL COVERAGE (this run) ----------------");
      cover_emit("fsm_idle",        cov_fsm_idle);
      cover_emit("fsm_ahb_pend",    cov_fsm_ahb_pend);
      cover_emit("fsm_time_pend",   cov_fsm_time_pend);
      cover_emit("time_req",        cov_time_req);
      cover_emit("time_gnt",        cov_time_gnt);
      cover_emit("wlo_busy",        cov_wlo_busy);
      cover_emit("whi_busy",        cov_whi_busy);
      cover_emit("wr_stall",        cov_wr_stall);
      cover_emit("hclk_en_hi",      cov_hclk_en_hi);
      cover_emit("hclk_en_lo",      cov_hclk_en_lo);
      cover_emit("irq_msw",         cov_irq_msw);
      cover_emit("irq_mtip",        cov_irq_mtip);
      cover_emit("irq_ssw",         cov_irq_ssw);
      cover_emit("wake_lf",         cov_wake_lf);
      cover_emit("hresp_err",       cov_hresp_err);
      cover_emit("pipelined",       cov_pipelined);
      cover_emit("wait_state",      cov_wait_state);
      cover_emit("htrans_seq",      cov_htrans_seq);
      cover_emit("htrans_busy",     cov_htrans_busy);
      cover_emit("subword",         cov_subword);
      cover_emit("mtip_top_hart",   cov_mtip_top_hart);
      cover_emit("mtip_masked",     cov_mtip_masked);
      $display("----------------------------------------------------------------");
   end
endtask
