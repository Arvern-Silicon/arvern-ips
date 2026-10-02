//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    hiperf_arb_contests
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : hiperf_arb_contests.v
// Module Description : Directed contests on the hiperf level-2 arbiters in
//                      front of the executable subordinates (s0 ROM, s1
//                      SRAM). Hiperf only; other variants skip.
//
// A contest is M0 (m_x) and an NX manager presenting an address phase to the
// same executable subordinate in the same cycle (blocking reads started at
// the same edge; the fabric adds no pipeline stage on either path). The
// winner is the one whose read completes first; every read's data is
// checked. Each lone access and each contest starts from the opposite
// priority state to the one it establishes, so a stuck or contest-only
// priority bit is caught.
//
// Expected winners follow from "priority goes to the channel NOT granted
// last (every grant counts, contested or not); m_x first after reset". The
// loser of a contest is granted right after the winner, alone, and that
// grant counts too: a contest repeated right after a contest is won by the
// same side again.
//
//   s1 (fresh)  C1 contest              -> m_x   (reset state)
//               C2 contest              -> m_x   (C1 loser's grant counted)
//               lone m_x, C3 (vs M2)    -> NX
//               C4 contest              -> NX    (C3 loser's grant counted)
//               lone NX (M2), C5        -> m_x
//               lone m_x, lone NX, C6   -> m_x
//               lone m_x, C7            -> NX
//               stream: 12 + 12 back-to-back reads, first completion NX,
//               no side completes more than HA_MAX_RUN transfers in a row
//               while the other still has transfers outstanding.
//   s0 (fresh)  lone m_x, C8            -> NX    (a lone grant moves it)
//               C9 contest              -> NX
//               lone NX (M2), C10       -> m_x
//
// Strict alternation of the stream is only printed: the doc fixes the
// winner when both channels request in the same cycle, but does not say the
// NX side re-requests in the very cycle the level-2 bus frees.
//
// Basis (quoted)
//  ahb_interconnect.md, What differs: "One ahb_arbiter_2m per executable
//    subordinate: priority goes to the channel NOT granted last (every grant
//    counts, contested or not); m_x first after reset"
//  ahb_interconnect.md, High-performance fabric: "The arbiter resets to
//    m_x-first and afterwards gives priority to the channel that was NOT
//    granted last. Every grant moves it, contested or not: a lone m_x fetch
//    hands priority to the non-executable side, so the next collision is won
//    by that side."
//  ahb_interconnect.md, Building blocks: "ahb_arbiter_2m | Two-manager
//    round-robin arbiter (one toggle-priority flop, reset to channel 0 = m_x
//    first). Hiperf only, one per executable subordinate."
//  ahb_interconnect.md, Generic fabric: "The fabric adds no pipeline stage:
//    an address phase reaches the selected subordinate in the cycle the
//    manager presents it"
//----------------------------------------------------------------------------

localparam [31:0] HA_ROM     = 32'h00400000;
localparam [31:0] HA_SRAM    = 32'h00401000;
localparam        HA_MAX_RUN = 4;

integer    ha_i;
integer    ha_j;
integer    ha_s0;
integer    ha_s1;
integer    ha_n0;
integer    ha_n1;
integer    ha_who;
integer    ha_last;
integer    ha_run;
integer    ha_maxrun;
integer    ha_first;
integer    ha_alt;
integer    ha_cnt;
reg [63:0] ha_tx;
reg [63:0] ha_tn;
reg [63:0] ha_t0;
reg [63:0] ha_t1;


//----------------------------------------------------------------------------
// Completion-time recorder for M0 and M1 (stream phase)
//----------------------------------------------------------------------------
reg        rc_out  [0:1];
integer    rc_n    [0:1];
integer    rc_errs [0:1];
reg [63:0] rc_time [0:511];
integer    rc_k;

initial
   for (rc_k = 0; rc_k < 2; rc_k = rc_k + 1)
      begin
         rc_out[rc_k]  = 1'b0;
         rc_n[rc_k]    = 0;
         rc_errs[rc_k] = 0;
      end

task rc_sample;
   input integer m;
   input         aph;
   input         rdy;
   input         rsp;
   begin
      if (rc_out[m] & rdy)
         begin
            rc_time[m*256 + (rc_n[m] % 256)] = $time;
            if (rsp) rc_errs[m] = rc_errs[m] + 1;
            rc_n[m]   = rc_n[m] + 1;
            rc_out[m] = 1'b0;
         end
      if (aph & rdy) rc_out[m] = 1'b1;
   end
endtask

always @(posedge free_clk)
   if (!hresetn)
      begin
         rc_out[0] = 1'b0;
         rc_out[1] = 1'b0;
      end
   else if (tb_rst_done)
      begin
         rc_sample(0, m0_htrans_d[1], m0_hready, m0_hresp);
         rc_sample(1, m1_htrans_d[1], m1_hready, m1_hresp);
      end


//----------------------------------------------------------------------------
// Helpers
//----------------------------------------------------------------------------
function [31:0] ha_val;
   input [31:0] a;
   begin
      if (a < HA_SRAM) ha_val = rom_inst0.mem[(a - HA_ROM) >> 2];
      else             ha_val = sram_inst0.mem[(a - HA_SRAM) >> 2];
   end
endfunction

task ha_lone;
   input integer m;
   input  [31:0] a;
   begin
      ahb_read(m, 1, a, ha_val(a), 2, 1);
      repeat(10) @(posedge free_clk);
   end
endtask

// Contest: m_x reads ax, NX manager nxm reads anx, same edge.
// exp_nx_first = 0: m_x must win; 1: the NX side must win.
task ha_contest;
   input integer    nxm;
   input     [31:0] ax;
   input     [31:0] anx;
   input            exp_nx_first;
   input [8*40-1:0] what;
   begin
      ha_tx = 0;
      ha_tn = 0;
      fork
         begin
            ahb_read(0,   1, ax,  ha_val(ax),  2, 1);
            ha_tx = $time;
         end
         begin
            ahb_read(nxm, 1, anx, ha_val(anx), 2, 1);
            ha_tn = $time;
         end
      join
      if (ha_tx == ha_tn)
         begin
            $display("ERROR: %0s: m_x and NX completed at the same edge -- not a contest on one subordinate", what);
            error = error + 1;
         end
      else if ((ha_tn < ha_tx) != exp_nx_first)
         begin
            $display("ERROR: %0s: %0s won, expected %0s (m_x done %0t, NX done %0t)", what,
                     (ha_tn < ha_tx) ? "NX" : "m_x", exp_nx_first ? "NX" : "m_x", ha_tx, ha_tn);
            error = error + 1;
         end
      else
         $display("PASS:  %0s: %0s won", what, exp_nx_first ? "NX" : "m_x");
      repeat(10) @(posedge free_clk);
   end
endtask


//----------------------------------------------------------------------------
// Stimulus
//----------------------------------------------------------------------------
initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(10) @(posedge free_clk);

`ifdef HIPERF
      $display("");
      $display(" =====================================================");
      $display("|  HIPERF LEVEL-2 ARBITER CONTESTS                    |");
      $display(" =====================================================");

      for (tb_idx = 0; tb_idx < MEM_SIZE/4; tb_idx = tb_idx + 1)
         begin
            rom_inst0.mem[tb_idx]  = 32'h0A000000 + (tb_idx * 32'h00010001);
            sram_inst0.mem[tb_idx] = 32'h5A000000 + (tb_idx * 32'h00010001);
         end

      @(negedge free_clk);
      force   ahb_periph_example_inst0.hresetn_i = 1'b0;
      force   ahb_periph_example_inst1.hresetn_i = 1'b0;
      @(negedge free_clk);
      release ahb_periph_example_inst0.hresetn_i;
      release ahb_periph_example_inst1.hresetn_i;
      repeat(10) @(posedge free_clk);

      //---------------------------------------------------------------
      // s1 (SRAM): nothing has accessed it since reset
      //---------------------------------------------------------------
      ha_contest(1, HA_SRAM + 32'h000, HA_SRAM + 32'h100, 1'b0, "s1 C1 first contest after reset        ");
      ha_contest(1, HA_SRAM + 32'h004, HA_SRAM + 32'h104, 1'b0, "s1 C2 contest right after a contest    ");

      ha_lone(0, HA_SRAM + 32'h008);
      ha_contest(2, HA_SRAM + 32'h00C, HA_SRAM + 32'h10C, 1'b1, "s1 C3 lone m_x then contest            ");
      ha_contest(1, HA_SRAM + 32'h010, HA_SRAM + 32'h110, 1'b1, "s1 C4 contest right after a contest    ");

      ha_lone(2, HA_SRAM + 32'h114);
      ha_contest(1, HA_SRAM + 32'h018, HA_SRAM + 32'h118, 1'b0, "s1 C5 lone NX then contest             ");

      ha_lone(0, HA_SRAM + 32'h01C);
      ha_lone(1, HA_SRAM + 32'h11C);
      ha_contest(2, HA_SRAM + 32'h020, HA_SRAM + 32'h120, 1'b0, "s1 C6 lone m_x, lone NX, contest       ");

      ha_lone(0, HA_SRAM + 32'h024);
      ha_contest(1, HA_SRAM + 32'h028, HA_SRAM + 32'h128, 1'b1, "s1 C7 lone m_x then contest            ");

      //---------------------------------------------------------------
      // s1 stream: priority is on the NX side here
      //---------------------------------------------------------------
      $display("");
      $display("s1 stream: m_x and M1, 12 back-to-back reads each");
      ha_n0 = rc_n[0];
      ha_n1 = rc_n[1];
      fork
         begin
            for (ha_s0 = 0; ha_s0 < 12; ha_s0 = ha_s0 + 1)
               ahb_read(0, 0, HA_SRAM + 32'h200 + 4*ha_s0, ha_val(HA_SRAM + 32'h200 + 4*ha_s0), 2, 1);
         end
         begin
            for (ha_s1 = 0; ha_s1 < 12; ha_s1 = ha_s1 + 1)
               ahb_read(1, 0, HA_SRAM + 32'h300 + 4*ha_s1, ha_val(HA_SRAM + 32'h300 + 4*ha_s1), 2, 1);
         end
      join
      repeat(30) @(posedge free_clk);

      if (((rc_n[0] - ha_n0) != 12) || ((rc_n[1] - ha_n1) != 12))
         begin
            $display("ERROR: stream: %0d m_x and %0d M1 completions, expected 12 each", rc_n[0] - ha_n0, rc_n[1] - ha_n1);
            error = error + 1;
         end
      else
         begin
            ha_i = ha_n0; ha_j = ha_n1;
            ha_last = -1; ha_run = 0; ha_maxrun = 0; ha_first = -1; ha_alt = 1; ha_cnt = 0;
            $write("INFO:  stream completion order: ");
            while ((ha_i < rc_n[0]) || (ha_j < rc_n[1]))
               begin
                  ha_t0 = rc_time[      (ha_i % 256)];
                  ha_t1 = rc_time[256 + (ha_j % 256)];
                  if ((ha_i < rc_n[0]) && (ha_j < rc_n[1]) && (ha_t0 == ha_t1))
                     begin
                        $display("");
                        $display("ERROR: stream: m_x and M1 completed at the same edge on one subordinate");
                        error = error + 1;
                     end
                  if ((ha_j >= rc_n[1]) || ((ha_i < rc_n[0]) && (ha_t0 < ha_t1)))
                     begin ha_who = 0; ha_i = ha_i + 1; end
                  else
                     begin ha_who = 1; ha_j = ha_j + 1; end
                  $write("%0s ", ha_who ? "NX" : "X");
                  if (ha_first < 0) ha_first = ha_who;
                  if (ha_who == ha_last) ha_run = ha_run + 1;
                  else                   ha_run = 1;
                  if (ha_who == ha_last) ha_alt = 0;
                  // A run only counts while the other side still has transfers left
                  if ((((ha_who == 0) && (ha_j < rc_n[1])) || ((ha_who == 1) && (ha_i < rc_n[0]))) &&
                      (ha_run > ha_maxrun))
                     ha_maxrun = ha_run;
                  ha_last = ha_who;
                  ha_cnt  = ha_cnt + 1;
               end
            $display("");
            if (ha_first != 1)
               begin
                  $display("ERROR: stream: first completion by m_x, expected NX (priority on NX after C7)");
                  error = error + 1;
               end
            else
               $display("PASS:  stream: first contest won by NX");
            if (ha_maxrun > HA_MAX_RUN)
               begin
                  $display("ERROR: stream: one side completed %0d transfers in a row while the other waited", ha_maxrun);
                  error = error + 1;
               end
            else
               $display("PASS:  stream: longest one-sided run %0d (bound %0d)", ha_maxrun, HA_MAX_RUN);
            $display("INFO:  stream strictly alternating: %0s", ha_alt ? "yes" : "no");
         end
      if ((rc_errs[0] != 0) || (rc_errs[1] != 0))
         begin
            $display("ERROR: ERROR responses on executable-subordinate reads");
            error = error + 1;
         end

      //---------------------------------------------------------------
      // s0 (ROM): nothing has accessed it since reset
      //---------------------------------------------------------------
      $display("");
      ha_lone(0, HA_ROM + 32'h000);
      ha_contest(1, HA_ROM + 32'h004, HA_ROM + 32'h104, 1'b1, "s0 C8 first contest after a lone m_x   ");
      ha_contest(1, HA_ROM + 32'h008, HA_ROM + 32'h108, 1'b1, "s0 C9 contest right after a contest    ");
      ha_lone(2, HA_ROM + 32'h10C);
      ha_contest(1, HA_ROM + 32'h010, HA_ROM + 32'h110, 1'b0, "s0 C10 lone NX then contest            ");
`else
      tb_skip_finish("|   (hiperf_arb_contests runs on the HIPERF fabric only)    |");
`endif

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
