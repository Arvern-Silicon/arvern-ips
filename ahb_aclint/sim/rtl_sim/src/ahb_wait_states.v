//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_wait_states
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_wait_states
// Module Description : Inject fabric wait states (hready_i held low by the
//                      interconnect) around AHB accesses and verify the DUT
//                      holds the address phase and completes the transfer with
//                      correct data. The standard BFM never drives hready_i=0
//                      on a normal access, so aph_valid's hready_i gating and
//                      the data-phase-extend behavior were unstimulated.
//                      Stall is injected via tb_force_stall (see tb).
//----------------------------------------------------------------------------

reg wait_seen;

// Observe a genuine wait state: data phase in flight while the bus is not
// ready. Sampled on free_clk (hclk_i may be gated).
initial wait_seen = 1'b0;
always @(posedge free_clk)
   if ((tb_ahb_aclint.dut.dph_valid === 1'b1) && (hready === 1'b0))
      wait_seen = 1'b1;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(20) @(posedge free_clk);

      $display(" ===============================================");
      $display("|        AHB : FABRIC WAIT-STATE INJECTION      |");
      $display(" ===============================================");

      // Baseline: MSIP[0] = 0.
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000000, 2, OK);

      // Stalled WRITE: inject 3 fabric wait states mid-transfer while the BFM
      // drives MSIP[0]=1. The DUT must hold the address phase until hready_i
      // rises, then latch and commit exactly once.
      fork
         begin : INJECT_W
            @(posedge free_clk);          // let the address phase be presented
            tb_force_stall = 1'b1;
            repeat(3) @(posedge free_clk);
            tb_force_stall = 1'b0;
         end
         ahb_write(1, MACHINE, 32'h00400000, 32'h00000001, 2, OK);
      join

      if (wait_seen) begin
         $display("PASS:  fabric wait state observed during stalled write %t ns", $time);
      end else begin
         $display("ERROR: no wait state observed -- hready_i injection had no effect %t ns", $time);
         error = error + 1;
      end

      // Stalled READ-BACK: confirm the write committed exactly the new value
      // (not dropped, not double-applied) -- and stall the read too.
      fork
         begin : INJECT_R
            @(posedge free_clk);
            tb_force_stall = 1'b1;
            repeat(2) @(posedge free_clk);
            tb_force_stall = 1'b0;
         end
         ahb_read(1, MACHINE, 32'h00400000, 32'h00000001, 2, 1, OK);
      join

      // Sanity: ensure the stall hook is released so it cannot leak into the
      // scoreboard / later cleanup.
      tb_force_stall = 1'b0;

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
