//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_atomic_read
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_atomic_read.v
// Module Description : Exercise the canonical RISC-V 64-on-32 MTIME read
//                      pattern: MTIME_LO triggers the CDC roundtrip and
//                      captures a coherent 64-bit snapshot; the subsequent
//                      MTIME_HI returns the buffered upper half (no CDC).
//                      Verify that two LO+HI pairs are monotonically
//                      non-decreasing.
//----------------------------------------------------------------------------

reg [63:0] t0;
reg [63:0] t1;
reg [63:0] hi_first_shadow;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(100) @(posedge free_clk);

      $display(" ===============================================");
      $display("|         MTIME : ATOMIC 64-BIT READ            |");
      $display(" ===============================================");

      // Bare HI read with no prior LO: mtime_shadow resets to 0, so the
      // returned HI is just 0 (no fresh sample). Just log it; do not
      // hard-check the value - the contract only forbids assuming it
      // is fresh.
      hi_first_shadow = tb_ahb_aclint.mtime_shadow_ahb_sim;
      ahb_read(1, MACHINE, 32'h0040400C, 32'h00000000, 2, 0, OK);
      $display("INFO:  pre-LO mtime_shadow snapshot = 0x%h %t ns",
               hi_first_shadow, $time);

      // First snapshot: LO triggers a roundtrip, then probe the full 64-bit
      // mtime_shadow (stable across the AHB read). HI access is verified
      // via a separate read after.
      ahb_read(1, MACHINE, 32'h00404008, 32'h00000000, 2, 0, OK);
      t0 = tb_ahb_aclint.mtime_shadow_ahb_sim;
      ahb_read(1, MACHINE, 32'h0040400C, 32'h00000000, 2, 0, OK);
      $display("INFO:  t0 = 0x%h_%h %t ns", t0[63:32], t0[31:0], $time);

      // Let MTIME advance a few LF ticks.
      repeat(200) @(posedge free_clk);

      // Second snapshot.
      ahb_read(1, MACHINE, 32'h00404008, 32'h00000000, 2, 0, OK);
      t1 = tb_ahb_aclint.mtime_shadow_ahb_sim;
      ahb_read(1, MACHINE, 32'h0040400C, 32'h00000000, 2, 0, OK);
      $display("INFO:  t1 = 0x%h_%h %t ns", t1[63:32], t1[31:0], $time);

      // 64-bit monotonicity check.
      if (t1 < t0) begin
         $display("ERROR: MTIME went backwards -- t0=0x%h t1=0x%h %t ns", t0, t1, $time);
         error = error + 1;
      end else if (t1 == t0) begin
         $display("WARNING: MTIME did not advance between snapshots -- t0==t1==0x%h (LF clock too slow?) %t ns",
                  t0, $time);
      end else begin
         $display("PASS:  MTIME advanced -- t1 - t0 = 0x%h %t ns", (t1 - t0), $time);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
