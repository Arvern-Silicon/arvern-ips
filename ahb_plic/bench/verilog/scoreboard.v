//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    scoreboard (ahb_plic tb include)
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : scoreboard.v
// Module Description : Always-on passive reference model + output monitor,
//                      `included into tb_ahb_plic. It independently re-derives
//                      the PLIC arbitration from the registered state arrays
//                      and compares against the DUT's per-context outputs every
//                      cycle, regardless of which stimulus runs. All sampling
//                      is on the ungated free_clk; all mismatches bump `error`.
//
//                      Per context (generate-for, so it scales with
//                      NUM_CONTEXTS and uses a constant index for the
//                      genblock-local threshold/irq probes):
//                        SB-EIP  irq_o must equal OR_s( pending & enable &
//                                (prio != 0) & (prio > threshold) ).
//                        SB-TOP  top_source_id (claim, threshold-independent)
//                                must equal the highest-priority pending&enabled
//                                source, ties broken by lowest ID.
//                      Global:
//                        SB-X    no DUT output may be X after reset.
//
//                      These reference models duplicate the spec, not the RTL
//                      wires, so an arbiter / threshold-compare / tie-break /
//                      priority-0 / enable-index bug in the DUT is caught
//                      continuously instead of only where a directed test
//                      happens to look.
//----------------------------------------------------------------------------

integer sb_checks;
reg     sb_active;

initial begin
   sb_active = 1'b0;
   sb_checks = 0;
   @(posedge hresetn);
   repeat (10) @(negedge free_clk);
   sb_active = 1'b1;
end

//----------------------------------------------------------------------------
// Per-context reference model (one checker instance per context).
//----------------------------------------------------------------------------
genvar sb_gc;
generate
for (sb_gc = 0; sb_gc < NUM_CONTEXTS; sb_gc = sb_gc + 1) begin : G_SB_CTX
   always @(negedge free_clk) if (sb_active) begin : eip_chk
      integer              s;
      reg [PRIO_BITS-1:0]  pr;
      reg [PRIO_BITS-1:0]  thr;
      reg                  eip_ref;
      reg [10:0]           top_ref;
      reg [PRIO_BITS-1:0]  top_prio;
      reg                  qual_claim;
      reg                  qual_irq;

      thr      = dut.G_TGT[sb_gc].u_target.threshold;
      eip_ref  = 1'b0;
      top_ref  = 11'h0;
      top_prio = {PRIO_BITS{1'b0}};

      // Iterate high-to-low with >= so the lowest source ID wins a tie,
      // exactly mirroring plic_target's arbiter loop.
      for (s = NUM_SOURCES; s >= 1; s = s - 1) begin
         pr         = dut.priority_flat[PRIO_BITS*s +: PRIO_BITS];
         qual_claim = dut.pending_flat[s] &
                      dut.enable_flat[(NUM_SOURCES+1)*sb_gc + s] &
                      (pr != {PRIO_BITS{1'b0}});
         qual_irq   = qual_claim & (pr > thr);
         if (qual_irq) eip_ref = 1'b1;
         if (qual_claim && (pr >= top_prio)) begin
            top_ref  = s[10:0];
            top_prio = pr;
         end
      end

      sb_checks = sb_checks + 1;

      // SB-EIP: threshold-masked interrupt line.
      if (eip_ref !== dut.tgt_irq[sb_gc]) begin
         $display("ERROR: SCOREBOARD SB-EIP ctx%0d -- model irq=%b but DUT tgt_irq=%b %t ns",
                  sb_gc, eip_ref, dut.tgt_irq[sb_gc], $time);
         error = error + 1;
      end

      // SB-TOP: threshold-independent claim winner / tie-break.
      if (top_ref !== dut.tgt_top_id[sb_gc]) begin
         $display("ERROR: SCOREBOARD SB-TOP ctx%0d -- model top_id=%0d but DUT top_id=%0d %t ns",
                  sb_gc, top_ref, dut.tgt_top_id[sb_gc], $time);
         error = error + 1;
      end
   end
end
endgenerate

//----------------------------------------------------------------------------
// SB-X : no DUT output may be X once the monitor is armed.
//----------------------------------------------------------------------------
always @(negedge free_clk) if (sb_active) begin
   if ( (^irq_m_external === 1'bx) ||
        (^irq_s_external === 1'bx) ||
        (hresp           === 1'bx) ||
        (hreadyout       === 1'bx) ||
        (hclk_en         === 1'bx) ) begin
      $display("ERROR: SCOREBOARD SB-X -- DUT output is X after reset (m=%b s=%b resp=%b rdy=%b en=%b) %t ns",
               irq_m_external, irq_s_external, hresp, hreadyout, hclk_en, $time);
      error = error + 1;
   end
end

//----------------------------------------------------------------------------
// End-of-sim report (called from tb_extra_report).
//----------------------------------------------------------------------------
task scoreboard_report;
   begin
      $display("SCOREBOARD: %0d reference-model checks executed (SB-EIP/SB-TOP per ctx, SB-X)", sb_checks);
      if (sb_checks == 0) begin
         $display("ERROR: SCOREBOARD never executed a check -- monitor was not armed %t ns", $time);
         error = error + 1;
      end
   end
endtask
