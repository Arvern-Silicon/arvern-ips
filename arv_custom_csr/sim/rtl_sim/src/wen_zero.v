//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    wen_zero
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : wen_zero.v
// Module Description : Negative-case write test. Drives a valid bank and
//                      reg_sel plus a non-zero sentinel wdata while keeping
//                      wen=0. Verifies the addressed RW register keeps its
//                      previous value across the bus pulse.
//----------------------------------------------------------------------------

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      $display(" ===============================================");
      $display("|             WEN=0 NEGATIVE WRITE TEST         |");
      $display(" ===============================================");

      // Plant a known value in one register of each RW bank
      repeat(10) @(posedge free_clk);
      csr_read_write(12'h800, 32'hCAFEBABE, 32'h00000000, 1);   // User Bank 0 reg 0
      csr_read_write(12'h5C0, 32'h12345678, 32'h00000000, 1);   // Sup  Bank 5 reg 0
      csr_read_write(12'h7C0, 32'h0BADF00D, 32'h00000000, 1);   // Mac  Bank 8 reg 0

      // The captured outputs must reflect the planted values immediately
      check_value(ccsr_usr_rw0, 32'hCAFEBABE);
      check_value(ccsr_sup_rw0, 32'h12345678);
      check_value(ccsr_mac_rw0, 32'h0BADF00D);

      // Attempt to overwrite each register with a sentinel value but wen=0.
      // The DUT must ignore it.
      repeat(5) @(posedge free_clk);
      csr_no_write_attempt(12'h800, 32'hDEADBEEF);
      csr_no_write_attempt(12'h5C0, 32'hDEADBEEF);
      csr_no_write_attempt(12'h7C0, 32'hDEADBEEF);

      // Reads must still return the original planted value
      repeat(5) @(posedge free_clk);
      csr_read(12'h800, 32'hCAFEBABE, 1);
      csr_read(12'h5C0, 32'h12345678, 1);
      csr_read(12'h7C0, 32'h0BADF00D, 1);

      // Captured output ports must also be unchanged
      check_value(ccsr_usr_rw0, 32'hCAFEBABE);
      check_value(ccsr_sup_rw0, 32'h12345678);
      check_value(ccsr_mac_rw0, 32'h0BADF00D);

      // Repeat with a different sentinel to rule out a coincidence
      repeat(5) @(posedge free_clk);
      csr_no_write_attempt(12'h800, 32'hFFFFFFFF);
      csr_no_write_attempt(12'h5C0, 32'hFFFFFFFF);
      csr_no_write_attempt(12'h7C0, 32'hFFFFFFFF);

      csr_read(12'h800, 32'hCAFEBABE, 1);
      csr_read(12'h5C0, 32'h12345678, 1);
      csr_read(12'h7C0, 32'h0BADF00D, 1);

      // Sanity: a normal write with wen=1 still works after the no-write probes
      repeat(5) @(posedge free_clk);
      csr_read_write(12'h800, 32'hAAAA5555, 32'hCAFEBABE, 1);
      check_value(ccsr_usr_rw0, 32'hAAAA5555);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
