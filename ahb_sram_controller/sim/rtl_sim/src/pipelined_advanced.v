//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    pipelined_advanced
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : pipelined_advanced.v
// Module Description : Advanced pipelined test exercising the
//                      READ_PENDING_WRITE hazard handling.
//----------------------------------------------------------------------------

integer ii;
integer jj;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);

      $display("");
      $display(" ===============================================");
      $display("|  PIPELINED AHB WRITE-READ SAVED: 32B          |");
      $display(" ===============================================");
      repeat(10) @(posedge free_clk);
      ahb_write(1, 32'h00400260, 'h13243546, 2);

      // Read back 32B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 32b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'hACBDBEDF, 2, 1);  // <-- this one reads from the pause buffer
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'hACBDBEDF, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);

      // Read back 16B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 16b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'hBEDF,     1, 1);  // <-- this one reads the lower half from the pause buffer
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021E, 'hACBD,     1, 1);  // <-- this one reads the higher half from the pause buffer
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'hACBDBEDF, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);

      // Read back 8B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 8b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'hDF,       0, 1);  // <-- this one reads bits [7:0]   from the pause buffer
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021D, 'hBE,       0, 1);  // <-- this one reads bits [15:8]  from the pause buffer
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021E, 'hBD,       0, 1);  // <-- this one reads bits [23:16] from the pause buffer
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021F, 'hAC,       0, 1);  // <-- this one reads bits [31:24] from the pause buffer
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'hACBDBEDF, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);


      $display("");
      $display("");
      $display(" ===============================================");
      $display("|  PIPELINED AHB WRITE-READ SAVED: 16B (lower)  |");
      $display(" ===============================================");
      repeat(10) @(posedge free_clk);
      ahb_write(1, 32'h00400260, 'h13243546, 2);

      // Read back 32B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 32b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021C, 'h9876,     1);     // <-- this one writes the lower half
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'hACBD9876, 2, 1);  // <-- this one reads the higher part from memory and the lower from the pause buffer
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'hACBD9876, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);

      // Read back 16B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 16b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021C, 'h9876,     1);     // <-- this one writes the lower half
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'h9876,     1, 1);  // <-- this one reads the lower half from the pause buffer
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021E, 'hACBD,     1, 1);  // <-- this one reads the higher half from the memory
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'hACBD9876, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);

      // Read back 8B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 8b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021C, 'h9876,     1);     // <-- this one writes the lower half
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'h76,       0, 1);  // <-- this one reads bits [7:0]   from the pause buffer
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021D, 'h98,       0, 1);  // <-- this one reads bits [15:8]  from the pause buffer
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021E, 'hBD,       0, 1);  // <-- this one reads bits [23:16] from the memory
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021F, 'hAC,       0, 1);  // <-- this one reads bits [31:24] from the memory
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'hACBD9876, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);


      $display("");
      $display("");
      $display(" ===============================================");
      $display("|  PIPELINED AHB WRITE-READ SAVED: 16B (upper)  |");
      $display(" ===============================================");
      repeat(10) @(posedge free_clk);
      ahb_write(1, 32'h00400260, 'h13243546, 2);

      // Read back 32B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 32b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021E, 'h9876,     1);     // <-- this one writes the upper half
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'h9876BEDF, 2, 1);  // <-- this one reads the higher part from memory and the lower from the pause buffer
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'h9876BEDF, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);

      // Read back 16B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 16b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021E, 'h9876,     1);     // <-- this one writes the upper half
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'hBEDF,     1, 1);  // <-- this one reads the lower half from the memory
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021E, 'h9876,     1, 1);  // <-- this one reads the upper half from the pause buffer
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'h9876BEDF, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);

      // Read back 8B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 8b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021E, 'h9876,     1);     // <-- this one writes the upper half
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'hDF,       0, 1);  // <-- this one reads bits [7:0]   from the memory
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021D, 'hBE,       0, 1);  // <-- this one reads bits [15:8]  from the memory
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021E, 'h76,       0, 1);  // <-- this one reads bits [23:16] from the pause buffer
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021F, 'h98,       0, 1);  // <-- this one reads bits [31:24] from the pause buffer
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'h9876BEDF, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);


      $display("");
      $display("");
      $display(" ===============================================");
      $display("|  PIPELINED AHB WRITE-READ SAVED: 8B - [7:0]   |");
      $display(" ===============================================");
      repeat(10) @(posedge free_clk);
      ahb_write(1, 32'h00400260, 'h13243546, 2);

      // Read back 32B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 32b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021C, 'h76,       0);     // <-- this one writes the bits [7:0]
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'hACBDBE76, 2, 1);  // <-- this one reads [31:8] from memory and [7:0] from the pause buffer
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'hACBDBE76, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);

      // Read back 16B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 16b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021C, 'h76,       0);     // <-- this one writes the bits [7:0]
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'hBE76,     1, 1);  // <-- this one reads [15:8] from memory and [7:0] from the pause buffer
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021E, 'hACBD,     1, 1);  // <-- this one reads [31:16] from the memory
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'hACBDBE76, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);

      // Read back 8B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 8b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021C, 'h76,       0);     // <-- this one writes the bits [7:0]
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'h76,       0, 1);  // <-- this one reads bits [7:0]   from the pause buffer
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021D, 'hBE,       0, 1);  // <-- this one reads bits [15:8]  from the memory
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021E, 'hBD,       0, 1);  // <-- this one reads bits [23:16] from the memory
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021F, 'hAC,       0, 1);  // <-- this one reads bits [31:24] from the memory
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'hACBDBE76, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);


      $display("");
      $display("");
      $display(" ===============================================");
      $display("|  PIPELINED AHB WRITE-READ SAVED: 8B - [15:8]  |");
      $display(" ===============================================");
      repeat(10) @(posedge free_clk);
      ahb_write(1, 32'h00400260, 'h13243546, 2);

      // Read back 32B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 32b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021D, 'h98,       0);     // <-- this one writes the bits [15:8]
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'hACBD98DF, 2, 1);  // <-- this one reads [31:16] and [7:0] from memory and [15:8] from the pause buffer
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'hACBD98DF, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);

      // Read back 16B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 16b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021D, 'h98,       0);     // <-- this one writes the bits [15:8]
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'h98DF,     1, 1);  // <-- this one reads [7:0] from memory and [15:8] from the pause buffer
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021E, 'hACBD,     1, 1);  // <-- this one reads [31:16] from the memory
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'hACBD98DF, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);

      // Read back 8B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 8b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021D, 'h98,       0);     // <-- this one writes the bits [15:8]
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'hDF,       0, 1);  // <-- this one reads bits [7:0]   from the memory
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021D, 'h98,       0, 1);  // <-- this one reads bits [15:8]  from the pause buffer
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021E, 'hBD,       0, 1);  // <-- this one reads bits [23:16] from the memory
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021F, 'hAC,       0, 1);  // <-- this one reads bits [31:24] from the memory
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'hACBD98DF, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);


      $display("");
      $display("");
      $display(" ===============================================");
      $display("|  PIPELINED AHB WRITE-READ SAVED: 8B - [23:16] |");
      $display(" ===============================================");
      repeat(10) @(posedge free_clk);
      ahb_write(1, 32'h00400260, 'h13243546, 2);

      // Read back 32B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 32b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021E, 'h76,       0);     // <-- this one writes the bits [23:16]
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'hAC76BEDF, 2, 1);  // <-- this one reads [31:24] and [15:0] from memory and [23:16] from the pause buffer
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'hAC76BEDF, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);

      // Read back 16B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 16b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021E, 'h76,       0);     // <-- this one writes the bits [23:16]
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'hBEDF,     1, 1);  // <-- this one reads [15:0] from the memory 
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021E, 'hAC76,     1, 1);  // <-- this one reads [31:24] from memory and [23:16] from the pause buffer
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'hAC76BEDF, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);

      // Read back 8B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 8b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021E, 'h76,       0);     // <-- this one writes the bits [23:16]
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'hDF,       0, 1);  // <-- this one reads bits [7:0]   from the memory
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021D, 'hBE,       0, 1);  // <-- this one reads bits [15:8]  from the memory
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021E, 'h76,       0, 1);  // <-- this one reads bits [23:16] from the pause buffer
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021F, 'hAC,       0, 1);  // <-- this one reads bits [31:24] from the memory
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'hAC76BEDF, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);


      $display("");
      $display("");
      $display(" ===============================================");
      $display("|  PIPELINED AHB WRITE-READ SAVED: 8B - [31:24] |");
      $display(" ===============================================");
      repeat(10) @(posedge free_clk);
      ahb_write(1, 32'h00400260, 'h13243546, 2);

      // Read back 32B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 32b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021F, 'h98,       0);     // <-- this one writes the bits [31:24]
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'h98BDBEDF, 2, 1);  // <-- this one reads [23:0] from memory and [31:24] from the pause buffer
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'h98BDBEDF, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);

      // Read back 16B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 16b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021F, 'h98,       0);     // <-- this one writes the bits [31:24]
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'hBEDF,     1, 1);  // <-- this one reads [15:0] from the memory 
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021E, 'h98BD,     1, 1);  // <-- this one reads [23:16] from memory and [31:24] from the pause buffer
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'h98BDBEDF, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);

      // Read back 8B before the restore
      //-------------------------------------------------------------
      $display("");
      $display("-- Read back before the write restore: 8b");
      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_write(0, 32'h0040021F, 'h98,       0);     // <-- this one writes the bits [31:24]
      ahb_read( 0, 32'h00400210, 'hCAFEC00F, 2, 1);
      ahb_read( 0, 32'h00400214, 'hDEADBEEF, 2, 1);
      ahb_read( 0, 32'h00400218, 'hBAD0BACC, 2, 1);
      ahb_read( 0, 32'h0040021C, 'hDF,       0, 1);  // <-- this one reads bits [7:0]   from the memory
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021D, 'hBE,       0, 1);  // <-- this one reads bits [15:8]  from the memory
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021E, 'hBD,       0, 1);  // <-- this one reads bits [23:16] from the memory
      ahb_read( 0, 32'h00400260, 'h13243546, 2, 1);
      ahb_read( 0, 32'h0040021F, 'h98,       0, 1);  // <-- this one reads bits [31:24] from the pause buffer
      ahb_read( 1, 32'h00400260, 'h13243546, 2, 1);

      $display("");
      $display("-- Read back from memory then re-init");
      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, 'h98BDBEDF, 2, 1);  // <-- this one reads from memory
      ahb_write(1, 32'h0040021C, 'h5A5AA5A5, 2);
      ahb_read( 1, 32'h0040021C, 'h5A5AA5A5, 2, 1);
      repeat(3) @(posedge free_clk);


      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
