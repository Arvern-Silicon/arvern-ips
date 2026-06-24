//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    simple_rdwr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : simple_rdwr.v
// Module Description : Simple read/write test stimulus for the Custom CSR
//                      peripheral.
//----------------------------------------------------------------------------

integer ii;
integer jj;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      $display(" ===============================================");
      $display("|            SIMPLE CCSR READ-WRITES            |");
      $display(" ===============================================");

      // Write to User-Mode CSRs

      repeat(10) @(posedge free_clk);
      csr_read_write(12'h802, 32'h12345678, 32'h00000000, 1);
      csr_read_write(12'h800, 32'h9ABCDEF0, 32'h00000000, 1);
      csr_read_write(12'h803, 32'h24354657, 32'h00000000, 1);
      csr_read_write(12'h801, 32'h35465768, 32'h00000000, 1);

      repeat(10) @(posedge free_clk);
      csr_read_write(12'h802, 32'hDEADBEEF, 32'h12345678, 1);
      csr_read_write(12'h800, 32'hBADC0FFE, 32'h9ABCDEF0, 1);
      csr_read_write(12'h803, 32'hBAB1F007, 32'h24354657, 1);
      csr_read_write(12'h801, 32'ha5a5a5a5, 32'h35465768, 1);

      repeat(10) @(posedge free_clk);
      csr_read_write(12'h802, 32'h00000000, 32'hDEADBEEF, 1);
      csr_read_write(12'h800, 32'h00000000, 32'hBADC0FFE, 1);
      csr_read_write(12'h803, 32'h00000000, 32'hBAB1F007, 1);
      csr_read_write(12'h801, 32'h00000000, 32'ha5a5a5a5, 1);

      repeat(10) @(posedge free_clk);
      csr_read_write(12'h802, 32'h00000000, 32'h00000000, 1);
      csr_read_write(12'h800, 32'h00000000, 32'h00000000, 1);
      csr_read_write(12'h803, 32'h00000000, 32'h00000000, 1);
      csr_read_write(12'h801, 32'h00000000, 32'h00000000, 1);


      $display(" ===============================================");
      $display("|            SIMPLE CCSR READ                   |");
      $display(" ===============================================");

      // Write to Machine-Mode CSRs to initialize values
      repeat(10) @(posedge free_clk);
      csr_read_write(12'h7C2, 32'hDEADBEEF, 32'h00000000, 1);
      csr_read_write(12'h7C0, 32'hBADC0FFE, 32'h00000000, 1);
      csr_read_write(12'h7C3, 32'hBAB1F007, 32'h00000000, 1);
      csr_read_write(12'h7C1, 32'ha5a5a5a5, 32'h00000000, 1);

      // Perform read access
      repeat(10) @(posedge free_clk);
      csr_read(12'h7C2, 32'hDEADBEEF, 1);
      csr_read(12'h7C0, 32'hBADC0FFE, 1);
      csr_read(12'h7C3, 32'hBAB1F007, 1);
      csr_read(12'h7C1, 32'ha5a5a5a5, 1);

      // Make sure the values didn't change
      repeat(10) @(posedge free_clk);
      csr_read_write(12'h7C2, 32'h00000000, 32'hDEADBEEF, 1);
      csr_read_write(12'h7C0, 32'h00000000, 32'hBADC0FFE, 1);
      csr_read_write(12'h7C3, 32'h00000000, 32'hBAB1F007, 1);
      csr_read_write(12'h7C1, 32'h00000000, 32'ha5a5a5a5, 1);

      repeat(10) @(posedge free_clk);
      csr_read_write(12'h7C2, 32'h00000000, 32'h00000000, 1);
      csr_read_write(12'h7C0, 32'h00000000, 32'h00000000, 1);
      csr_read_write(12'h7C3, 32'h00000000, 32'h00000000, 1);
      csr_read_write(12'h7C1, 32'h00000000, 32'h00000000, 1);


      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
