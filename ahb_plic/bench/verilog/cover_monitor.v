//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    cover_monitor (ahb_plic tb include)
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
//                      `included into tb_ahb_plic. Each bin is a sticky flag
//                      raised the first time its condition is seen. cover_report
//                      emits one "COVERAGE HIT: <bin>" line per raised bin;
//                      run_sweep.py unions these across all configs and FAILS
//                      the sweep if any sim_configs.MANDATORY_COVER_BINS entry
//                      was never hit -- the suite-level gate that makes an
//                      unexercised state/interface visible. Bins use '=== 1'b1'
//                      compares so reset-time X never raises one. All sampling
//                      on the ungated free_clk.
//----------------------------------------------------------------------------

reg cov_eip_m_hi;
reg cov_eip_s_hi;
reg cov_hclk_en_hi;
reg cov_hclk_en_lo;
reg cov_hresp_err;
reg cov_pending_any;
reg cov_in_service_any;
reg cov_size_err;
reg cov_prio0_blocked;
reg cov_threshold_masks;
reg cov_claim_nonzero;
reg cov_claim_pulse;
reg cov_complete_pulse;
reg cov_multiword;

initial begin
   cov_eip_m_hi      = 1'b0; cov_eip_s_hi       = 1'b0;
   cov_hclk_en_hi    = 1'b0; cov_hclk_en_lo     = 1'b0;
   cov_hresp_err     = 1'b0;
   cov_pending_any   = 1'b0; cov_in_service_any = 1'b0;
   cov_size_err      = 1'b0;
   cov_prio0_blocked = 1'b0; cov_threshold_masks= 1'b0;
   cov_claim_nonzero = 1'b0;
   cov_claim_pulse   = 1'b0; cov_complete_pulse = 1'b0;
   cov_multiword     = 1'b0;
end

// ---- Global (context-independent) bins ----
integer cs;
reg [PRIO_BITS-1:0] cprio;
always @(negedge free_clk) begin
   if (|irq_m_external === 1'b1) cov_eip_m_hi = 1'b1;
   if (|irq_s_external === 1'b1) cov_eip_s_hi = 1'b1;
   if (hclk_en === 1'b1) cov_hclk_en_hi = 1'b1;
   if (hclk_en === 1'b0) cov_hclk_en_lo = 1'b1;
   if (hresp   === 1'b1) cov_hresp_err  = 1'b1;
   if (|dut.pending_flat[NUM_SOURCES:1]    === 1'b1) cov_pending_any    = 1'b1;
   if (|dut.in_service_flat[NUM_SOURCES:1] === 1'b1) cov_in_service_any = 1'b1;
   if ((dut.dph_valid === 1'b1) && (dut.dph_size !== 3'b010)) cov_size_err = 1'b1;

   // priority-0 "never interrupt": a pending+enabled (ctx0) source at priority 0.
   for (cs = 1; cs <= NUM_SOURCES; cs = cs + 1) begin
      cprio = dut.priority_flat[PRIO_BITS*cs +: PRIO_BITS];
      if ((dut.pending_flat[cs] === 1'b1) &&
          (dut.enable_flat[cs]  === 1'b1) &&
          (cprio === {PRIO_BITS{1'b0}}))
         cov_prio0_blocked = 1'b1;
      // multi-word: a high-index source (>31) enabled in ctx0.
      if ((cs > 31) && (dut.enable_flat[cs] === 1'b1))
         cov_multiword = 1'b1;
   end
end

// ---- Per-context bins (constant genvar index for genblock probes) ----
genvar cgc;
generate
for (cgc = 0; cgc < NUM_CONTEXTS; cgc = cgc + 1) begin : G_COV_CTX
   integer ks;
   reg [PRIO_BITS-1:0] kprio;
   reg [PRIO_BITS-1:0] kthr;
   always @(negedge free_clk) begin
      kthr = dut.G_TGT[cgc].u_target.threshold;
      if (dut.tgt_top_id[cgc] !== 11'h0) cov_claim_nonzero = 1'b1;
      if (dut.tgt_claim_p[cgc] === 1'b1) cov_claim_pulse    = 1'b1;
      if (dut.tgt_compl_p[cgc] === 1'b1) cov_complete_pulse = 1'b1;
      for (ks = 1; ks <= NUM_SOURCES; ks = ks + 1) begin
         kprio = dut.priority_flat[PRIO_BITS*ks +: PRIO_BITS];
         // threshold masking: qualifying source held below threshold.
         if ((dut.pending_flat[ks] === 1'b1) &&
             (dut.enable_flat[(NUM_SOURCES+1)*cgc + ks] === 1'b1) &&
             (kprio !== {PRIO_BITS{1'b0}}) &&
             (kprio <= kthr))
            cov_threshold_masks = 1'b1;
      end
   end
end
endgenerate

//----------------------------------------------------------------------------
// End-of-sim emit (called from tb_extra_report).
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
      cover_emit("eip_m_hi",       cov_eip_m_hi);
      cover_emit("eip_s_hi",       cov_eip_s_hi);
      cover_emit("hclk_en_hi",     cov_hclk_en_hi);
      cover_emit("hclk_en_lo",     cov_hclk_en_lo);
      cover_emit("hresp_err",      cov_hresp_err);
      cover_emit("pending_any",    cov_pending_any);
      cover_emit("in_service_any", cov_in_service_any);
      cover_emit("size_err",       cov_size_err);
      cover_emit("prio0_blocked",  cov_prio0_blocked);
      cover_emit("threshold_masks",cov_threshold_masks);
      cover_emit("claim_nonzero",  cov_claim_nonzero);
      cover_emit("claim_pulse",    cov_claim_pulse);
      cover_emit("complete_pulse", cov_complete_pulse);
      cover_emit("multiword",      cov_multiword);
      $display("----------------------------------------------------------------");
   end
endtask
