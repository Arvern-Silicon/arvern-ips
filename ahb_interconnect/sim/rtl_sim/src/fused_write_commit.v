//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    fused_write_commit
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : fused_write_commit.v
// Module Description : Fused fabric: a Port-B (NX) write to executable SRAM
//                      must reach the macro within a bounded number of cycles
//                      while Port A (M0, the X manager) fetches back-to-back,
//                      and a later Port-A fetch of that word must be fresh.
//
//                      Fabric-level counterpart of unit test T44 in
//                      tb_ahb_fused_sram_ctrl.v; run with -fused and with
//                      -fused -fixed_b_prio to cover both arbitration schemes.
//----------------------------------------------------------------------------

integer ii;
integer jj;
integer commit_cyc;
reg     stream_on;

localparam WR_ADDR       = 32'h00401040;        // executable SRAM, word 16
localparam WR_WORD       = (WR_ADDR - 32'h00401000) >> 2;
localparam WR_VAL        = 32'hC0DE0001;
localparam OLD_VAL       = 32'h0BAD0BAD;
localparam COMMIT_BOUND  = 8;                    // cycles after the write data phase

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(10) @(posedge free_clk);

      $display("");
      $display(" =====================================================");
      $display("|   FUSED: B WRITE COMMIT UNDER CONTINUOUS A FETCH    |");
      $display(" =====================================================");
      repeat(10) @(posedge free_clk);

      // ROM random, SRAM cleared, the target word pre-loaded with a known
      // old value so a stale fetch is unambiguous.
      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
         rom_inst0.mem[tb_idx]  = $urandom;
      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
         sram_inst0.mem[tb_idx] = 32'h00000000;
      for (tb_idx=0; tb_idx < 8; tb_idx=tb_idx+1)
         sram_inst0.mem[tb_idx] = 32'h11110000 + tb_idx;
      sram_inst0.mem[WR_WORD]   = OLD_VAL;

      @(negedge free_clk);
      force   ahb_periph_example_inst0.hresetn_i = 1'b0;
      force   ahb_periph_example_inst1.hresetn_i = 1'b0;
      @(negedge free_clk);
      release ahb_periph_example_inst0.hresetn_i;
      release ahb_periph_example_inst1.hresetn_i;
      repeat(10) @(posedge free_clk);
      $display("");

      commit_cyc = -1;
      stream_on  = 1'b1;

      fork
         begin                                                     // M0 -- Port A: fetch stream, no IDLE cycle
            // 60 back-to-back NONSEQ reads over SRAM words 0..7 (non-blocking:
            // the next APH is presented in the cycle the previous one is accepted)
            for (ii = 0; ii < 60; ii = ii+1)
               ahb_read( 0, 0, 32'h00401000 + 4*(ii % 8), 32'h11110000 + (ii % 8), 2, 1);
            // ... then, still without a bubble, 8 fetches of the written word.
            // COMMIT_BOUND cycles have long passed: every one must be fresh.
            for (ii = 0; ii < 7; ii = ii+1)
               ahb_read( 0, 0, WR_ADDR, WR_VAL, 2, 1);
            ahb_read( 0, 1, WR_ADDR, WR_VAL, 2, 1);
            stream_on = 1'b0;
         end
         begin                                                     // M1 -- Port B: one write, 5 cycles into the stream
            repeat(5) @(posedge free_clk);
            ahb_write(1, 1, WR_ADDR, WR_VAL, 2);
            // Count cycles from the end of the write data phase until the
            // bench SRAM model holds the new value.
            jj = 0;
            while ((sram_inst0.mem[WR_WORD] !== WR_VAL) && stream_on) begin
               @(posedge free_clk);
               jj = jj + 1;
            end
            if (sram_inst0.mem[WR_WORD] === WR_VAL) commit_cyc = jj;
         end
      join

      if (commit_cyc < 0)
         tb_error("B write never reached the SRAM while Port A was fetching      ");
      else if (commit_cyc > COMMIT_BOUND)
         begin
            $display("ERROR: B write landed %0d cycles after its data phase (bound %0d)", commit_cyc, COMMIT_BOUND);
            error = error + 1;
         end
      else
         $display("PASS:  B write landed %0d cycle(s) after its data phase (bound %0d)", commit_cyc, COMMIT_BOUND);

      // Stream stopped: the write must be in the macro now in any case.
      repeat(4) @(posedge free_clk);
      check_mem_value(WR_WORD, WR_VAL);
      ahb_read( 1, 1, WR_ADDR, WR_VAL, 2, 1);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
