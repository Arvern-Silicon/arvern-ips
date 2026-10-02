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
//                        SB-GW   pending / in-service per source must equal a
//                                gateway model driven only by irq_src_i and the
//                                claims / completes seen on the bus: a claim
//                                takes the ID the claim read returned, a
//                                complete counts only when the spec's rule
//                                admits it (ID 1..NUM_SOURCES as a whole word,
//                                enabled for the completing context).
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

      // Iterate high-to-low with >= so the lowest source ID wins a tie (the
      // spec's rule; plic_target implements it as a compare tree).
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
// SB-GW : gateway / claim / complete reference model.
//----------------------------------------------------------------------------
reg  [NUM_SOURCES:1] gw_pend;
reg  [NUM_SOURCES:1] gw_insvc;
reg                  gw_dph;          // a transfer's data phase is in progress
reg           [21:0] gw_addr;
reg                  gw_write;
reg           [10:0] gw_ctx;
reg                  gw_is_claim;
reg                  gw_claim_ev;
reg                  gw_compl_ev;
reg           [10:0] gw_claim_id;
reg           [10:0] gw_compl_id;
integer              gw_s;

// The bus signals are sampled mid-cycle, where they are stable: stimulus changes them
// on the rising edge, and reading them there would race the DUT. irq_src_i reaches
// the DUT 1 ns after the stimulus drives it, so it never moves on a clock edge and is
// read on the DUT's own edge -- a source raised while the clock is gated wakes it for
// a single edge, which a mid-cycle copy would miss.
reg                  gw_hready, gw_hsel, gw_hwrite, gw_hreadyout, gw_hresp;
reg            [1:0] gw_htrans;
reg           [21:0] gw_haddr;
reg           [31:0] gw_hwdata, gw_hrdata;

always @(negedge free_clk) begin
   gw_hready    <= hready;
   gw_hsel      <= hsel;
   gw_htrans    <= htrans;
   gw_haddr     <= haddr[21:0];
   gw_hwrite    <= hwrite;
   gw_hwdata    <= hwdata;
   gw_hrdata    <= hrdata;
   gw_hreadyout <= hreadyout;
   gw_hresp     <= hresp;
end

always @(posedge hclk or negedge hresetn) begin
   if (!hresetn) begin
      gw_pend  <= {NUM_SOURCES{1'b0}};
      gw_insvc <= {NUM_SOURCES{1'b0}};
      gw_dph   <= 1'b0;
      gw_addr  <= 22'h0;
      gw_write <= 1'b0;
   end else begin
      // Claim / complete registers: 0x200000 + 0x1000*ctx + 0x4.
      gw_ctx      = gw_addr[21:12] - 10'h200;
      gw_is_claim = (gw_addr[21:12] >= 10'h200) && (gw_ctx < NUM_CONTEXTS) &&
                    (gw_addr[11:0] == 12'h004);
      // Only transfers that complete with OKAY count (a denied one is ERROR).
      gw_claim_ev = gw_dph & ~gw_write & gw_is_claim & gw_hreadyout & ~gw_hresp &
                    (gw_hrdata[10:0] != 11'h0);
      gw_claim_id = gw_hrdata[10:0];
      gw_compl_id = gw_hwdata[10:0];
      gw_compl_ev = gw_dph & gw_write & gw_is_claim & gw_hreadyout & ~gw_hresp &
                    (gw_hwdata[31:11] == 21'h0) && (gw_compl_id != 11'h0) &&
                    (gw_compl_id <= NUM_SOURCES) &&
                    dut.enable_flat[(NUM_SOURCES+1)*gw_ctx + gw_compl_id];
      for (gw_s = 1; gw_s <= NUM_SOURCES; gw_s = gw_s + 1) begin
         if (gw_claim_ev && (gw_claim_id == gw_s)) begin
            gw_pend[gw_s]  <= 1'b0;
            gw_insvc[gw_s] <= 1'b1;
         end else begin
            if (~gw_insvc[gw_s] & irq_src_i[gw_s]) gw_pend[gw_s] <= 1'b1;
            if (gw_compl_ev && (gw_compl_id == gw_s)) gw_insvc[gw_s] <= 1'b0;
         end
      end
      // Address phase bookkeeping; held while hready is low.
      if (gw_hready) begin
         gw_dph   <= gw_hsel & gw_htrans[1];
         gw_addr  <= gw_haddr;
         gw_write <= gw_hwrite;
      end
   end
end

always @(negedge free_clk) if (sb_active && hresetn) begin
   sb_checks = sb_checks + 1;
   if ((gw_pend !== dut.pending_flat[NUM_SOURCES:1]) ||
       (gw_insvc !== dut.in_service_flat[NUM_SOURCES:1])) begin
      $display("ERROR: SCOREBOARD SB-GW -- model pending=%h in_service=%h but DUT pending=%h in_service=%h %t ns",
               gw_pend, gw_insvc, dut.pending_flat[NUM_SOURCES:1], dut.in_service_flat[NUM_SOURCES:1], $time);
      error = error + 1;
   end
end

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
      $display("SCOREBOARD: %0d reference-model checks executed (SB-EIP/SB-TOP per ctx, SB-GW, SB-X)", sb_checks);
      if (sb_checks == 0) begin
         $display("ERROR: SCOREBOARD never executed a check -- monitor was not armed %t ns", $time);
         error = error + 1;
      end
   end
endtask
