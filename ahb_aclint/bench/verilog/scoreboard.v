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
//                      tb_ahb_aclint. It observes DUT outputs that were
//                      previously left dangling and enforces continuous
//                      invariants regardless of which stimulus is running.
//                      All checks sample free_clk (the ungated reference) so
//                      they still fire even if hclk_i is frozen, and all
//                      increment the shared `error` counter.
//
//                      Invariants:
//                        SC1  time_gnt_o  => hclk_en_o   (the clock-gate bug:
//                             on the grant cycle time_gnt_r is the sole term
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
// SC4 : no DUT output may be X after the monitor is armed. (^bus === x) is 1
// iff any bit of the bus is X. Catches uninitialised flops / X-propagation
// that "passed" before because nobody read these outputs.
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
// SC5 : observability / wiring of the two outputs the original escape left
// dangling. time_val_o is the registered Zicntr shadow; mtimer_wake_lf_o is
// the raw LF comparator level. Mismatches here flag a future re-wire/refactor
// and keep both ports continuously read (no longer dangling).
//----------------------------------------------------------------------------
always @(negedge free_clk) if (sb_active) begin
   if (time_val !== tb_ahb_aclint.dut.u_mtimer.mtime_shadow_zicntr) begin
      $display("ERROR: SCOREBOARD SC5 -- time_val_o 0x%h != internal mtime_shadow_zicntr 0x%h %t ns",
               time_val, tb_ahb_aclint.dut.u_mtimer.mtime_shadow_zicntr, $time);
      error = error + 1;
   end
   if (mtimer_wake_lf !== tb_ahb_aclint.dut.u_mtimer.irq_m_timer_lf) begin
      $display("ERROR: SCOREBOARD SC5 -- mtimer_wake_lf_o %b != internal irq_m_timer_lf %b %t ns",
               mtimer_wake_lf, tb_ahb_aclint.dut.u_mtimer.irq_m_timer_lf, $time);
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
