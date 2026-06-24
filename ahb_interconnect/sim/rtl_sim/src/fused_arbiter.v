//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    fused_arbiter
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : fused_arbiter.v
// Module Description : Fused-interconnect arbiter test stimulus.
//----------------------------------------------------------------------------

integer ii;
integer jj;

// Arbitration scheme verification (Phase 2): timestamps captured when each
// contending master completes its data phase.  The ordering between m0 and
// m1 reveals which port won the first contest inside the fused SRAM ctrl.
time    m0_done_time;
time    m1_done_time;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(10) @(posedge free_clk);

      $display("");
      $display(" =====================================================");
      $display("|        FUSED SPACED ARBITRATION  M0 / M1 / M2       |");
      $display(" =====================================================");
      repeat(10) @(posedge free_clk);

      // Initialize the ROM with random values (M0 will read these via Port A)
      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
         rom_inst0.mem[tb_idx]  = $urandom;

      // Clear the SRAM, then seed a few words so M0 (read-only) can hit known
      // values without first depending on M1/M2 commits.
      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
         sram_inst0.mem[tb_idx] = 32'h00000000;
      sram_inst0.mem[ 0] = 32'hA5A5A5A5;
      sram_inst0.mem[ 1] = 32'h5A5A5A5A;
      sram_inst0.mem[ 2] = 32'hCAFEC0DE;
      sram_inst0.mem[ 3] = 32'hF00DBABE;
      sram_inst0.mem[ 4] = 32'h11112222;
      sram_inst0.mem[ 5] = 32'h33334444;
      sram_inst0.mem[ 6] = 32'h55556666;
      sram_inst0.mem[ 7] = 32'h77778888;

      // Reset the peripherals
      @(negedge free_clk);
      force   ahb_periph_example_inst0.hresetn_i = 1'b0;
      force   ahb_periph_example_inst1.hresetn_i = 1'b0;
      @(negedge free_clk);
      release ahb_periph_example_inst0.hresetn_i;
      release ahb_periph_example_inst1.hresetn_i;

      repeat(10) @(posedge free_clk);
      $display("");

      fork
         begin                                                     // AHB Master 0 -- READ-ONLY (Port A)
            ahb_read( 0, 1, 32'h00400000, rom_inst0.mem[0],   2, 1);
            repeat(15) @(posedge free_clk);
            ahb_read( 0, 1, 32'h00400004, rom_inst0.mem[1],   2, 1);
            repeat(15) @(posedge free_clk);
            ahb_read( 0, 1, 32'h00401000, 32'hA5A5A5A5,       2, 1);
            repeat(15) @(posedge free_clk);
            ahb_read( 0, 1, 32'h00401004, 32'h5A5A5A5A,       2, 1);
            repeat(15) @(posedge free_clk);
            ahb_read( 0, 1, 32'h00400008, rom_inst0.mem[2],   2, 1);
            repeat(15) @(posedge free_clk);
            ahb_read( 0, 1, 32'h00401008, 32'hCAFEC0DE,       2, 1);
            repeat(15) @(posedge free_clk);
            ahb_read( 0, 1, 32'h0040000C, rom_inst0.mem[3],   2, 1);
            repeat(15) @(posedge free_clk);
         end
         begin                                                     // AHB Master 1 -- R/W (Port B)
            ahb_write(1, 1, 32'h00403000, 'hB00BAFE1,         2   );
            repeat(15) @(posedge free_clk);
            ahb_write(1, 1, 32'h00402000, 'hBAD0BACC,         2   );
            repeat(15) @(posedge free_clk);
            ahb_write(1, 1, 32'h00401010, 'h9ABCDEF0,         2   );
            repeat(15) @(posedge free_clk);
            ahb_read( 1, 1, 32'h00401010, 'h9ABCDEF0,         2, 1);
            repeat(15) @(posedge free_clk);
            ahb_read( 1, 1, 32'h00402000, 'hBAD0BACC,         2, 1);
            repeat(15) @(posedge free_clk);
            ahb_read( 1, 1, 32'h00403000, 'hB00BAFE1,         2, 1);
            repeat(15) @(posedge free_clk);
         end
         begin                                                     // AHB Master 2 -- R/W (Port B)
            ahb_write(2, 1, 32'h00401018, 'hABCDEF01,         2   );
            repeat(15) @(posedge free_clk);
            ahb_write(2, 1, 32'h00402018, 'hF0123456,         2   );
            repeat(15) @(posedge free_clk);
            ahb_write(2, 1, 32'h00403018, 'h456789AB,         2   );
            repeat(15) @(posedge free_clk);
            ahb_read( 2, 1, 32'h00401018, 'hABCDEF01,         2, 1);
            repeat(15) @(posedge free_clk);
            ahb_read( 2, 1, 32'h00402018, 'hF0123456,         2, 1);
            repeat(15) @(posedge free_clk);
            ahb_read( 2, 1, 32'h00403018, 'h456789AB,         2, 1);
            repeat(15) @(posedge free_clk);
         end
      join
      repeat(10) @(posedge free_clk);

      // NOTE: A back-to-back pipelined phase (hbusreq=0 on M0 + M1 + M2) is
      // intentionally NOT included.  When M0 streams Port-A reads against
      // sustained Port-B writes, the fused FSM hangs (Port-A SRAM read
      // starvation).  This matches the V2 review finding H-1 -- 'force_drain'
      // missing the '~post_read' guard.  Re-enable a pipelined section once
      // that fix lands.

      //---------------------------------------------------------------
      // ARBITRATION SCHEME VERIFICATION
      //---------------------------------------------------------------
      // Synchronously launch one Port-A read (M0) and one Port-B read (M1)
      // targeting the same fused SRAM controller.  After both complete,
      // compare $realtime to determine which port won the contest.
      //
      // The toggle_priority FF inside the RR arbiter retains state from the
      // earlier spaced phase, so we first issue an isolated M1 read.  Any
      // M1-wins event drives toggle_priority back to 0 (== Port-A priority
      // for the NEXT contest).  In Fixed-B mode this priming read is a
      // harmless single B transaction (no toggle_priority FF exists).
      //
      // After priming, the expected outcomes are:
      //   Round-robin:           M0 wins -> M0 finishes FIRST.
      //   Fixed Port-B priority: M1 always wins -> M1 finishes FIRST.
      //
      // The expected ordering is selected at compile time via the
      // FUSED_FIXED_B_PRIO macro -- mismatch flags a tb_error.
      $display("");
      $display(" =====================================================");
`ifdef FUSED_FIXED_B_PRIO
      $display("|     ARBITRATION CHECK: FIXED PORT-B PRIORITY        |");
`else
      $display("|     ARBITRATION CHECK: ROUND-ROBIN (Port-A first)   |");
`endif
      $display(" =====================================================");
      repeat(20) @(posedge free_clk);

      // Pre-seed three distinct SRAM words: one for the priming read,
      // two for the contending reads.
      sram_inst0.mem['h03C >> 2] = 32'hCCCCCCCC;
      sram_inst0.mem['h040 >> 2] = 32'hAAAAAAAA;
      sram_inst0.mem['h044 >> 2] = 32'hBBBBBBBB;
      repeat(5) @(posedge free_clk);

      // Priming: isolated M1 read normalizes toggle_priority to 0 in RR mode
      ahb_read( 1, 1, 32'h0040103C, 32'hCCCCCCCC, 2, 1);
      repeat(20) @(posedge free_clk);

      m0_done_time = 0;
      m1_done_time = 0;

      fork
         begin                                                     // M0 -- Port A
            ahb_read( 0, 1, 32'h00401040, 32'hAAAAAAAA, 2, 1);
            m0_done_time = $realtime;
         end
         begin                                                     // M1 -- Port B
            ahb_read( 1, 1, 32'h00401044, 32'hBBBBBBBB, 2, 1);
            m1_done_time = $realtime;
         end
      join
      repeat(10) @(posedge free_clk);

`ifdef FUSED_FIXED_B_PRIO
      if (m1_done_time < m0_done_time)
         $display("PASS:  Fixed B-prio scheme: M1 (Port B) won contention -- M1 done @ %0t, M0 done @ %0t", m1_done_time, m0_done_time);
      else
         tb_error("Fixed B-prio scheme expected M1 to finish before M0 ");
`else
      if (m0_done_time < m1_done_time)
         $display("PASS:  Round-robin scheme: M0 (Port A) won initial contention -- M0 done @ %0t, M1 done @ %0t", m0_done_time, m1_done_time);
      else
         tb_error("Round-robin scheme expected M0 to finish before M1 ");
`endif

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
