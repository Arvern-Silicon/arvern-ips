//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    scoreboard (ahb_aclint tb include)
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : scoreboard.v
// Module Description : Always-on passive output monitor, `included into
//                      tb_ahb_aclint. It observes DUT outputs continuously
//                      and enforces invariants regardless of which stimulus
//                      is running.
//                      All checks sample free_clk (the ungated reference) so
//                      they still fire even if hclk_i is frozen, and all
//                      increment the shared `error` counter.
//
//                      Invariants:
//                        SC1  time_gnt_o  => hclk_en_o   (on the grant
//                             cycle time_gnt_r is the sole term
//                             holding mtimer_active_o/hclk_en_o high; if that
//                             term is missing the gate drops while time_gnt is
//                             high -- caught here continuously).
//                        SC2  |irq_s_software_o => hclk_en_o  (same shape for
//                             the SSWI 1-cycle pulse via sswi_active).
//                        SC3  time_gnt_o is a pulse, never stuck high.
//                        SC4  no DUT output is X once both resets are released.
//                        SC5  wiring/observability of time_val_o and
//                             mtimer_wake_lf_o (X-guarded, tied to their
//                             internal sources).
//----------------------------------------------------------------------------

integer sb_checks;
integer sb_gnt_high_run;
reg     sb_active;

initial begin
   sb_active       = 1'b0;
   sb_checks       = 0;
   sb_gnt_high_run = 0;
   // Arm only after BOTH the hclk and LF resets have deasserted (they release
   // at different times) plus a settle margin, so power-up X / reset values
   // are never flagged.
   @(posedge hresetn);
   @(posedge resetn_lf);
   repeat (10) @(negedge free_clk);
   sb_active = 1'b1;
end

//----------------------------------------------------------------------------
// SC1 / SC2 : a 1-cycle handshake output must never be asserted while the
// SoC clock-gate advisory is low. hclk_en_o must hold hclk_i alive for the
// cleanup edge that clears the handshake flop.
//----------------------------------------------------------------------------
always @(negedge free_clk) if (sb_active) begin
   sb_checks = sb_checks + 1;

   // SC1 -- the exact clock-gate / time_gnt_r invariant.
   if ((time_gnt === 1'b1) && (hclk_en !== 1'b1)) begin
      $display("ERROR: SCOREBOARD SC1 -- time_gnt high while hclk_en low (clock gate would strand time_gnt_r) %t ns", $time);
      error = error + 1;
   end

   // SC2 -- same shape for the SSWI pulse (sswi_active term of hclk_en_o).
   if ((|irq_s_software === 1'b1) && (hclk_en !== 1'b1)) begin
      $display("ERROR: SCOREBOARD SC2 -- irq_s_software high while hclk_en low (sswi_active dropped early) %t ns", $time);
      error = error + 1;
   end

   // SC3 -- time_gnt_o must be a pulse, not a level. Generous threshold so a
   // clock-phase artifact never trips it; a real stuck grant is indefinite.
   if (time_gnt === 1'b1) sb_gnt_high_run = sb_gnt_high_run + 1;
   else                   sb_gnt_high_run = 0;
   if (sb_gnt_high_run >= 3) begin
      $display("ERROR: SCOREBOARD SC3 -- time_gnt stuck high for %0d cycles (handshake flop not clearing) %t ns", sb_gnt_high_run, $time);
      error = error + 1;
      sb_gnt_high_run = 0;   // report once per stuck episode
   end
end

//----------------------------------------------------------------------------
// SC4 : none of the DUT outputs below may be X after the monitor is armed.
// (^bus === x) is 1 iff any bit of the bus is X. Catches uninitialised flops /
// X-propagation on outputs that a test may never read.
//----------------------------------------------------------------------------
always @(negedge free_clk) if (sb_active) begin
   if ( (^irq_m_software === 1'bx) ||
        (^irq_m_timer    === 1'bx) ||
        (^irq_s_software  === 1'bx) ||
        (^mtimer_wake_lf  === 1'bx) ||
        (time_gnt         === 1'bx) ||
        (^time_val        === 1'bx) ||
        (hclk_en          === 1'bx) ||
        (hresp            === 1'bx) ||
        (hreadyout        === 1'bx) ) begin
      $display("ERROR: SCOREBOARD SC4 -- DUT output is X after reset (msw=%b mtim=%b ssw=%b wake=%b gnt=%b val=0x%h en=%b resp=%b rdy=%b) %t ns",
               irq_m_software, irq_m_timer, irq_s_software, mtimer_wake_lf,
               time_gnt, time_val, hclk_en, hresp, hreadyout, $time);
      error = error + 1;
   end
end

//----------------------------------------------------------------------------
// SC5 : observability / wiring of time_val_o and mtimer_wake_lf_o.
// time_val_o is the registered Zicntr shadow;
// mtimer_wake_lf_o is the raw LF comparator level. Mismatches flag a re-wire,
// and the check keeps both ports continuously read.
//----------------------------------------------------------------------------
always @(negedge free_clk) if (sb_active) begin
   if (time_val !== tb_ahb_aclint.dut.u_mtimer.mtime_shadow_zicntr) begin
      $display("ERROR: SCOREBOARD SC5 -- time_val_o 0x%h != internal mtime_shadow_zicntr 0x%h %t ns",
               time_val, tb_ahb_aclint.dut.u_mtimer.mtime_shadow_zicntr, $time);
      error = error + 1;
   end
   // mtimer_wake_lf_o is a SINGLE BIT: the OR across harts. The consumer is a
   // power controller restarting the main oscillator, which is system-wide and
   // has no use for a hart index -- that is carried by irq_m_timer_o[] once the
   // clock is back. Check the reduction, not per-hart equality.
   if (mtimer_wake_lf !== (|tb_ahb_aclint.dut.u_mtimer.wake_lf)) begin
      $display("ERROR: SCOREBOARD SC5 -- mtimer_wake_lf_o %b != OR of internal wake_lf %b %t ns",
               mtimer_wake_lf, tb_ahb_aclint.dut.u_mtimer.wake_lf, $time);
      error = error + 1;
   end
end

//----------------------------------------------------------------------------
// End-of-sim report (called from tb_extra_report).
//----------------------------------------------------------------------------
task scoreboard_report;
   begin
      $display("SCOREBOARD: %0d passive checks executed (SC1/SC2/SC3 clock-gate, SC4 X-prop, SC5 wiring)", sb_checks);
   end
endtask

// SC6 -- LIVENESS OF THE OSCILLATOR-ENABLE CONTRACT. The IP holds hclk_en_o
// while an AHB transfer or a time request is in flight, and the doc requires
// the oscillator controller to keep hclk_aon_i running while hclk_en_o (or any
// other IP's request) is high. If the controller ignores that -- or the SoC
// ties hclk_aon_en_i low -- an MTIME read stalls forever and csrr time never
// grants: a silicon hang no value check can see, because nothing advances.
// Counted on clk_lf so the check survives a stopped hclk_aon: two full LF
// periods of "transfer or time request pending, clock reported gone" is
// beyond any legitimate wake latency.
integer sb_aon_gone_lf;
initial sb_aon_gone_lf = 0;
always @(posedge clk_lf) if (sb_active) begin
   if ((dut.dph_valid === 1'b1 || time_req === 1'b1) && (hclk_aon_en === 1'b0))
      sb_aon_gone_lf = sb_aon_gone_lf + 1;
   else
      sb_aon_gone_lf = 0;
   if (sb_aon_gone_lf == 3) begin
      $display("ERROR: SCOREBOARD SC6 -- hclk_aon_en low for 2 clk_lf periods with a transfer or time request pending (oscillator-enable contract violated) %t ns", $time);
      error = error + 1;
   end
end

