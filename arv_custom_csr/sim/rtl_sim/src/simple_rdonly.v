//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    simple_rdonly
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : simple_rdonly.v
// Module Description : Read-Only banks test stimulus. Exercises Bank 4
//                      (User RO), Bank 7 (Supervisor RO) and Bank 10
//                      (Machine RO). Verifies reads track the driven
//                      RO inputs and that wen=1 on RO addresses has no
//                      effect.
//----------------------------------------------------------------------------

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      $display(" ===============================================");
      $display("|              SIMPLE CCSR READ-ONLY            |");
      $display(" ===============================================");

      // RO inputs are initialised to 0 by the TB --> reads return 0.
      repeat(10) @(posedge free_clk);
      csr_read(12'hCC0, 32'h00000000, 1);   // User RO   reg 0
      csr_read(12'hCC1, 32'h00000000, 1);   // User RO   reg 1
      csr_read(12'hDC0, 32'h00000000, 1);   // Sup  RO   reg 0
      csr_read(12'hDC1, 32'h00000000, 1);   // Sup  RO   reg 1
      csr_read(12'hFC0, 32'h00000000, 1);   // Mac  RO   reg 0
      csr_read(12'hFC1, 32'h00000000, 1);   // Mac  RO   reg 1

      // Drive distinct values onto each RO input. The mux is purely
      // combinational so the next read should reflect them.
      ccsr_usr_ro0 = 32'hAAAA0000;
      ccsr_usr_ro1 = 32'hAAAA0001;
      ccsr_sup_ro0 = 32'hBBBB0000;
      ccsr_sup_ro1 = 32'hBBBB0001;
      ccsr_mac_ro0 = 32'hCCCC0000;
      ccsr_mac_ro1 = 32'hCCCC0001;

      repeat(5) @(posedge free_clk);
      csr_read(12'hCC0, 32'hAAAA0000, 1);
      csr_read(12'hCC1, 32'hAAAA0001, 1);
      csr_read(12'hDC0, 32'hBBBB0000, 1);
      csr_read(12'hDC1, 32'hBBBB0001, 1);
      csr_read(12'hFC0, 32'hCCCC0000, 1);
      csr_read(12'hFC1, 32'hCCCC0001, 1);

      // wen=1 on a RO address must be a no-op:
      //   - the bank selector for the RO bank ignores wen entirely
      //   - the RW-bank selectors are not enabled (different bank bit)
      // The read should still return the driven RO input.
      repeat(5) @(posedge free_clk);
      csr_read_write(12'hCC0, 32'hDEADBEEF, 32'hAAAA0000, 1);
      csr_read_write(12'hDC1, 32'hDEADBEEF, 32'hBBBB0001, 1);
      csr_read_write(12'hFC0, 32'hDEADBEEF, 32'hCCCC0000, 1);

      // Re-read with wen=0 and confirm nothing was latched anywhere.
      csr_read(12'hCC0, 32'hAAAA0000, 1);
      csr_read(12'hDC1, 32'hBBBB0001, 1);
      csr_read(12'hFC0, 32'hCCCC0000, 1);

      // Change the inputs again and verify reads track immediately.
      ccsr_usr_ro0 = 32'h12345678;
      ccsr_sup_ro1 = 32'h87654321;
      ccsr_mac_ro0 = 32'h0F0F0F0F;
      repeat(2) @(posedge free_clk);
      csr_read(12'hCC0, 32'h12345678, 1);
      csr_read(12'hDC1, 32'h87654321, 1);
      csr_read(12'hFC0, 32'h0F0F0F0F, 1);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
