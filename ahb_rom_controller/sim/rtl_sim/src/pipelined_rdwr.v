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
// Module Description : Pipelined read/write test stimulus for the AHB ROM
//                      controller.
//----------------------------------------------------------------------------

integer        ii;
integer        jj;
reg     [31:0] exp_value;
reg     [31:0] exp_value1;
reg     [31:0] exp_value2;
reg     [31:0] exp_value3;
reg     [31:0] exp_value4;
reg     [31:0] exp_value5;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      // Initialiye the ROM with random values
      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
        rom_inst.mem[tb_idx] = $urandom;

      $display(" ===============================================");
      $display("|              PIPELINED AHB WRITES             |");
      $display(" ===============================================");

      // Pipelined 8b AHB Write accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      exp_value = rom_inst.mem['h088];
      ahb_write(0, 32'h00400220, 'h0F, 0);
      ahb_write(0, 32'h00400221, 'hC0, 0);
      ahb_write(0, 32'h00400222, 'hFE, 0);
      ahb_write(1, 32'h00400223, 'hCA, 0);
      check_mem_value('h088,     exp_value);
      
      $display("");

      // Pipelined 16b AHB Write accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      exp_value1 = rom_inst.mem['h08C];
      exp_value2 = rom_inst.mem['h08D];
      ahb_write(0, 32'h00400230, 'hBEEF, 1);
      ahb_write(0, 32'h00400232, 'hDEAD, 1);
      ahb_write(0, 32'h00400234, 'hBACC, 1);
      ahb_write(1, 32'h00400236, 'hBAD0, 1);
      check_mem_value('h08C,     exp_value1);
      check_mem_value('h08D,     exp_value2);

      $display("");

      // Pipelined 32b AHB Write accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      exp_value1 = rom_inst.mem['h090];
      exp_value2 = rom_inst.mem['h091];
      exp_value3 = rom_inst.mem['h092];
      exp_value4 = rom_inst.mem['h093];
      ahb_write(0, 32'h00400240, 'h12345678, 2);
      ahb_write(0, 32'h00400244, 'h9ABCDEF0, 2);
      ahb_write(0, 32'h00400248, 'hA5A55A5A, 2);
      ahb_write(1, 32'h0040024C, 'h43219876, 2);
      check_mem_value('h090,     exp_value1);
      check_mem_value('h091,     exp_value2);
      check_mem_value('h092,     exp_value3);
      check_mem_value('h093,     exp_value4);

      $display("");

      $display(" ===============================================");
      $display("|              PIPELINED AHB READS              |");
      $display(" ===============================================");

      // Pipelined 8b AHB Read accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      exp_value1 = rom_inst.mem['h088];
      exp_value2 = rom_inst.mem['h090];
      ahb_read(0, 32'h00400220, exp_value1[7:0],       0, 1);
      ahb_read(0, 32'h00400240, exp_value2,            2, 1);
      ahb_read(0, 32'h00400221, exp_value1[15:8],      0, 1);
      ahb_read(0, 32'h00400240, exp_value2,            2, 1);
      ahb_read(0, 32'h00400222, exp_value1[23:16],     0, 1);
      ahb_read(0, 32'h00400240, exp_value2,            2, 1);
      ahb_read(0, 32'h00400223, exp_value1[31:24],     0, 1);
      ahb_read(1, 32'h00400240, exp_value2,            2, 1);

      $display("");

      // Pipelined 16b AHB Read accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      exp_value1 = rom_inst.mem['h090];
      exp_value2 = rom_inst.mem['h08C];
      exp_value3 = rom_inst.mem['h08D];
      ahb_read(0, 32'h00400230, exp_value2[15:0],     1, 1);
      ahb_read(0, 32'h00400240, exp_value1,           2, 1);
      ahb_read(0, 32'h00400232, exp_value2[31:16],    1, 1);
      ahb_read(0, 32'h00400240, exp_value1,           2, 1);
      ahb_read(0, 32'h00400234, exp_value3[15:0],     1, 1);
      ahb_read(0, 32'h00400240, exp_value1,           2, 1);
      ahb_read(0, 32'h00400236, exp_value3[31:16],    1, 1);
      ahb_read(1, 32'h00400240, exp_value1,           2, 1);

      $display("");

      // Pipelined 32b AHB Read accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      exp_value1 = rom_inst.mem['h090];
      exp_value2 = rom_inst.mem['h091];
      exp_value3 = rom_inst.mem['h092];
      exp_value4 = rom_inst.mem['h093];
      ahb_read(0, 32'h00400240, exp_value1, 2, 1);
      ahb_read(0, 32'h00400244, exp_value2, 2, 1);
      ahb_read(0, 32'h00400248, exp_value3, 2, 1);
      ahb_read(1, 32'h0040024C, exp_value4, 2, 1);

      $display("");

      $display(" ===============================================");
      $display("|          PIPELINED AHB READ/WRITE             |");
      $display(" ===============================================");
      repeat(10) @(posedge free_clk);
      exp_value1 = rom_inst.mem['h090];
      exp_value2 = rom_inst.mem['h091];
      exp_value3 = rom_inst.mem['h092];
      exp_value4 = rom_inst.mem['h093];
      exp_value5 = rom_inst.mem['h094];

      ahb_read( 0, 32'h00400240, exp_value1[7:0],       0, 1);
      ahb_read( 0, 32'h00400245, exp_value2[15:8],      0, 1);
      ahb_read( 0, 32'h0040024A, exp_value3[23:16],     0, 1);
      ahb_read( 0, 32'h0040024F, exp_value4[31:24],     0, 1);
      ahb_write(0, 32'h00400250, 'hDF,                  0);
      ahb_write(0, 32'h00400251, 'hBE,                  0);
      ahb_write(0, 32'h00400252, 'hBD,                  0);
      ahb_write(1, 32'h00400253, 'hAC,                  0);
      check_mem_value('h090,     exp_value1);
      check_mem_value('h091,     exp_value2);
      check_mem_value('h092,     exp_value3);
      check_mem_value('h093,     exp_value4);
      check_mem_value('h094,     exp_value5);

      $display("");

      $display(" ===============================================");
      $display("|          PIPELINED AHB WRITE/READ             |");
      $display(" ===============================================");
      repeat(10) @(posedge free_clk);
      exp_value1 = rom_inst.mem['h084];
      exp_value2 = rom_inst.mem['h085];
      exp_value3 = rom_inst.mem['h086];
      exp_value4 = rom_inst.mem['h087];
      exp_value5 = rom_inst.mem['h098];

      ahb_write(0, 32'h00400210, 'hCAFEC00F, 2);
      ahb_write(0, 32'h00400214, 'hDEADBEEF, 2);
      ahb_write(0, 32'h00400218, 'hBAD0BACC, 2);
      ahb_write(0, 32'h0040021C, 'hACBDBEDF, 2);
      ahb_read( 0, 32'h00400210, exp_value1, 2, 1);
      ahb_read( 0, 32'h00400214, exp_value2, 2, 1);
      ahb_read( 0, 32'h00400218, exp_value3, 2, 1);
      ahb_read( 0, 32'h0040021C, exp_value4, 2, 1);
      ahb_read( 1, 32'h00400260, exp_value5, 2, 1);

      repeat(3) @(posedge free_clk);
      ahb_read( 1, 32'h0040021C, exp_value4, 2, 1);


      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
