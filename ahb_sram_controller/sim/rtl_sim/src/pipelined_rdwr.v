//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    pipelined_rdwr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : pipelined_rdwr.v
// Module Description : Pipelined read/write test stimulus for the AHB SRAM
//                      controller.
//----------------------------------------------------------------------------

integer ii;
integer jj;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      $display(" ===============================================");
      $display("|              PIPELINED AHB WRITES             |");
      $display(" ===============================================");

      // Pipelined 8b AHB Write accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      ahb_write(0, 32'h00400220, 'h0F, 0);
      ahb_write(0, 32'h00400221, 'hC0, 0);
      ahb_write(0, 32'h00400222, 'hFE, 0);
      ahb_write(1, 32'h00400223, 'hCA, 0);
      check_mem_value('h088,     'hCAFEC00F);
      
      $display("");

      // Pipelined 16b AHB Write accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      ahb_write(0, 32'h00400230, 'hBEEF, 1);
      ahb_write(0, 32'h00400232, 'hDEAD, 1);
      ahb_write(0, 32'h00400234, 'hBACC, 1);
      ahb_write(1, 32'h00400236, 'hBAD0, 1);
      check_mem_value('h08C,     'hDEADBEEF);
      check_mem_value('h08D,     'hBAD0BACC);

      $display("");

      // Pipelined 32b AHB Write accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      ahb_write(0, 32'h00400240, 'h12345678, 2);
      ahb_write(0, 32'h00400244, 'h9ABCDEF0, 2);
      ahb_write(0, 32'h00400248, 'hA5A55A5A, 2);
      ahb_write(1, 32'h0040024C, 'h43219876, 2);
      check_mem_value('h090,     'h12345678);
      check_mem_value('h091,     'h9ABCDEF0);
      check_mem_value('h092,     'hA5A55A5A);
      check_mem_value('h093,     'h43219876);

      $display("");

      $display(" ===============================================");
      $display("|              PIPELINED AHB READS              |");
      $display(" ===============================================");

      // Pipelined 8b AHB Read accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      ahb_read(0, 32'h00400220, 'h0F,       0, 1);
      ahb_read(0, 32'h00400240, 'h12345678, 2, 1);
      ahb_read(0, 32'h00400221, 'hC0,       0, 1);
      ahb_read(0, 32'h00400240, 'h12345678, 2, 1);
      ahb_read(0, 32'h00400222, 'hFE,       0, 1);
      ahb_read(0, 32'h00400240, 'h12345678, 2, 1);
      ahb_read(0, 32'h00400223, 'hCA,       0, 1);
      ahb_read(1, 32'h00400240, 'h12345678, 2, 1);

      $display("");

      // Pipelined 16b AHB Read accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      ahb_read(0, 32'h00400230, 'hBEEF,     1, 1);
      ahb_read(0, 32'h00400240, 'h12345678, 2, 1);
      ahb_read(0, 32'h00400232, 'hDEAD,     1, 1);
      ahb_read(0, 32'h00400240, 'h12345678, 2, 1);
      ahb_read(0, 32'h00400234, 'hBACC,     1, 1);
      ahb_read(0, 32'h00400240, 'h12345678, 2, 1);
      ahb_read(0, 32'h00400236, 'hBAD0,     1, 1);
      ahb_read(1, 32'h00400240, 'h12345678, 2, 1);

      $display("");

      // Pipelined 32b AHB Read accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      ahb_read(0, 32'h00400240, 'h12345678, 2, 1);
      ahb_read(0, 32'h00400244, 'h9ABCDEF0, 2, 1);
      ahb_read(0, 32'h00400248, 'hA5A55A5A, 2, 1);
      ahb_read(1, 32'h0040024C, 'h43219876, 2, 1);

      $display("");

      $display(" ===============================================");
      $display("|          PIPELINED AHB READ/WRITE             |");
      $display(" ===============================================");
      repeat(10) @(posedge free_clk);

      ahb_read( 0, 32'h00400240, 'h78,       0, 1);
      ahb_read( 0, 32'h00400245, 'hDE,       0, 1);
      ahb_read( 0, 32'h0040024A, 'hA5,       0, 1);
      ahb_read( 0, 32'h0040024F, 'h43,       0, 1);
      ahb_write(0, 32'h00400250, 'hDF,       0);
      ahb_write(0, 32'h00400251, 'hBE,       0);
      ahb_write(0, 32'h00400252, 'hBD,       0);
      ahb_write(1, 32'h00400253, 'hAC,       0);
      check_mem_value('h094,     'hACBDBEDF);

      $display("");

      $display(" ===============================================");
      $display("|          PIPELINED AHB WRITE/READ             |");
      $display(" ===============================================");
      repeat(10) @(posedge free_clk);

      // First run where we restore the read before reading back
      //-----------------------------------------------------------
      $display("-- First run where we restore the write before reading back");
      ahb_write(0, 32'h00400260, 'h13243546, 2);
      ahb_write(0, 32'h00400264, 'h57687980, 2);
      ahb_write(0, 32'h00400268, 'hACBEDF90, 2);
      ahb_write(0, 32'h0040026C, 'hA1B2C3D4, 2);
      ahb_read( 0, 32'h00400220, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400230, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400234, 'hBAD0BACC, 2, 1);
      ahb_read( 1, 32'h00400250, 'hACBDBEDF, 2, 1);

      repeat(3) @(posedge free_clk);
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h00400264, 'h57687980, 2, 1);
      ahb_read( 0, 32'h00400268, 'hACBEDF90, 2, 1);
      ahb_read( 1, 32'h0040026C, 'hA1B2C3D4, 2, 1);

      $display("");

      // Second run where we read back before the restore
      //-------------------------------------------------------------
      $display("-- Second run where we read back before the restore the write");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'hACBDBEDF, 2, 1);  // <-- this one reads from the pause buffer
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'hACBDBEDF, 2, 1);  // <-- this one reads from memory

      // Third run where we write-read back to back before the restore
      //-------------------------------------------------------------
      $display("-- Third run where we write-read back to back before the restore");
      repeat(10) @(posedge free_clk);
      ahb_write(0, 32'h00400218, 'hDEADBEEF, 2);
      ahb_read( 1, 32'h00400218, 'hDEADBEEF, 2, 1);  // <-- this one reads from the pause buffer
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h00400218, 'hDEADBEEF, 2, 1);  // <-- this one reads from memory

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
