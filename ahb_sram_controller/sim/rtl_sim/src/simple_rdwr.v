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
// Module Description : Simple read/write test stimulus for the AHB SRAM
//                      controller.
//----------------------------------------------------------------------------

integer ii;
integer jj;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      $display(" ===============================================");
      $display("|               SIMPLE AHB WRITES               |");
      $display(" ===============================================");

      // Non-Pipelined 8b AHB Write accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      ahb_write(1, 32'h00400220, 'h0F, 0);
      check_mem_value('h088, 'h0000000F);

      repeat(5) @(posedge free_clk);
      ahb_write(1, 32'h00400221, 'hC0, 0);
      check_mem_value('h088, 'h0000C00F);

      repeat(5) @(posedge free_clk);
      ahb_write(1, 32'h00400222, 'hFE, 0);
      check_mem_value('h088, 'h00FEC00F);

      repeat(5) @(posedge free_clk);
      ahb_write(1, 32'h00400223, 'hCA, 0);
      check_mem_value('h088, 'hCAFEC00F);

      $display("");

      // Non-Pipelined 16b AHB Write accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      ahb_write(1, 32'h00400230, 'hBEEF, 1);
      check_mem_value('h08C, 'h0000BEEF);

      repeat(5) @(posedge free_clk);
      ahb_write(1, 32'h00400232, 'hDEAD, 1);
      check_mem_value('h08C, 'hDEADBEEF);

      $display("");

      // Non-Pipelined 32b AHB Write accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      ahb_write(1, 32'h00400240, 'h12345678, 2);
      check_mem_value('h090, 'h12345678);

      $display("");

      $display(" ===============================================");
      $display("|               SIMPLE AHB READS                |");
      $display(" ===============================================");

      // Non-Pipelined 8b AHB Read accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      ahb_read(1, 32'h00400220, 'h0F,       0, 1);
      @(posedge free_clk);
      ahb_read(1, 32'h00400240, 'h12345678, 2, 1);

      repeat(5) @(posedge free_clk);
      ahb_read(1, 32'h00400221, 'hC0,       0, 1);
      @(posedge free_clk);
      ahb_read(1, 32'h00400240, 'h12345678, 2, 1);

      repeat(5) @(posedge free_clk);
      ahb_read(1, 32'h00400222, 'hFE,       0, 1);
      @(posedge free_clk);
      ahb_read(1, 32'h00400240, 'h12345678, 2, 1);

      repeat(5) @(posedge free_clk);
      ahb_read(1, 32'h00400223, 'hCA,       0, 1);
      @(posedge free_clk);
      ahb_read(1, 32'h00400240, 'h12345678, 2, 1);

      $display("");

      // Non-Pipelined 16b AHB Read accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      ahb_read(1, 32'h00400230, 'hBEEF,     1, 1);
      @(posedge free_clk);
      ahb_read(1, 32'h00400220, 'hCAFEC00F, 2, 1);

      repeat(5) @(posedge free_clk);
      ahb_read(1, 32'h00400232, 'hDEAD,     1, 1);
      @(posedge free_clk);
      ahb_read(1, 32'h00400220, 'hCAFEC00F, 2, 1);

      $display("");

      // Non-Pipelined 32b AHB Read accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      ahb_read(1, 32'h00400240, 'h12345678, 2, 1);
      @(posedge free_clk);
      ahb_read(1, 32'h00400230, 'hDEADBEEF, 2, 1);


      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
