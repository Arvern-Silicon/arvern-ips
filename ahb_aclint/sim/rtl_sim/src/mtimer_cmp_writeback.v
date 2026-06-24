//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_cmp_writeback
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_cmp_writeback.v
// Module Description : Write each half of MTIMECMP[0] and verify the
//                      hclk-domain shadow read-back. The shadow updates
//                      synchronously, so no LF wait is required.
//                      With NUM_HARTS=1, 0x4008/0x400C are MTIME_LO/HI -
//                      checked with no fixed expected value (runtime).
//----------------------------------------------------------------------------

reg [31:0] mtime_lo_sample;
reg [31:0] mtime_hi_sample;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|         MTIMECMP : SHADOW READ-BACK           |");
      $display(" ===============================================");

      // MTIMECMP_LO[0] write + read-back
      ahb_write(1, MACHINE, 32'h00404000, 32'hDEADBEEF, 2, OK);
      ahb_read (1, MACHINE, 32'h00404000, 32'hDEADBEEF, 2, 1, OK);

      // MTIMECMP_HI[0] write + read-back
      ahb_write(1, MACHINE, 32'h00404004, 32'hCAFEF00D, 2, OK);
      ahb_read (1, MACHINE, 32'h00404004, 32'hCAFEF00D, 2, 1, OK);

      // With NUM_HARTS=1 the address 0x4008/0x400C are MTIME_LO/HI - reads
      // launch a CDC roundtrip (LO) and return the buffered HI; values are
      // runtime dependent. Just confirm the address responds and check that
      // the returned value is NOT the MTIMECMP pattern we just wrote.
      $display(" ===============================================");
      $display("|       MTIME_LO/HI (overlaps post-cmp slot)    |");
      $display(" ===============================================");

      // Use the hclk-domain mtime_shadow probe: it is the stable register
      // that latches the 64-bit snapshot returned by the LO read, so it is
      // safe to sample after the AHB task returns.
      ahb_read(1, MACHINE, 32'h00404008, 32'h00000000, 2, 0, OK);
      mtime_lo_sample = tb_ahb_aclint.mtime_shadow_ahb_sim[31:0];
      mtime_hi_sample = tb_ahb_aclint.mtime_shadow_ahb_sim[63:32];
      $display("INFO:  MTIME (via shadow) = 0x%h_%h %t ns",
               mtime_hi_sample, mtime_lo_sample, $time);
      if (mtime_lo_sample === 32'hDEADBEEF) begin
         $display("ERROR: MTIME_LO returned the MTIMECMP_LO[0] value -- aliasing bug? %t ns", $time);
         error = error + 1;
      end
      if (mtime_hi_sample === 32'hCAFEF00D) begin
         $display("ERROR: MTIME_HI returned the MTIMECMP_HI[0] value -- aliasing bug? %t ns", $time);
         error = error + 1;
      end

      // HI read itself (no CDC; returns the buffered shadow's upper half).
      ahb_read(1, MACHINE, 32'h0040400C, 32'h00000000, 2, 0, OK);

      // Re-confirm MTIMECMP shadows are intact (the MTIME reads must not
      // disturb the shadow registers).
      ahb_read(1, MACHINE, 32'h00404000, 32'hDEADBEEF, 2, 1, OK);
      ahb_read(1, MACHINE, 32'h00404004, 32'hCAFEF00D, 2, 1, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
