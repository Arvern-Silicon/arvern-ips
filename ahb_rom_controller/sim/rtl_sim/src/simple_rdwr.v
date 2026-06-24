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
// Module Description : Simple read/write test stimulus for the AHB ROM
//                      controller.
//----------------------------------------------------------------------------

integer        ii;
integer        jj;
reg     [31:0] exp_value;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      // Initialiye the ROM with random values
      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
        rom_inst.mem[tb_idx] = $urandom;

      $display(" ===============================================");
      $display("|               SIMPLE AHB WRITES               |");
      $display(" ===============================================");

      // Non-Pipelined 8b AHB Write accesses
      //--------------------------------------------------
      exp_value = rom_inst.mem['h088];

      repeat(10) @(posedge free_clk);
      ahb_write(1, 32'h00400220, 'h0F, 0);
      check_mem_value('h088, exp_value);

      repeat(5) @(posedge free_clk);
      ahb_write(1, 32'h00400221, 'hC0, 0);
      check_mem_value('h088, exp_value);

      repeat(5) @(posedge free_clk);
      ahb_write(1, 32'h00400222, 'hFE, 0);
      check_mem_value('h088, exp_value);

      repeat(5) @(posedge free_clk);
      ahb_write(1, 32'h00400223, 'hCA, 0);
      check_mem_value('h088, exp_value);

      $display("");

      // Non-Pipelined 16b AHB Write accesses
      //--------------------------------------------------
      exp_value = rom_inst.mem['h08C];

      repeat(10) @(posedge free_clk);
      ahb_write(1, 32'h00400230, 'hBEEF, 1);
      check_mem_value('h08C, exp_value);

      repeat(5) @(posedge free_clk);
      ahb_write(1, 32'h00400232, 'hDEAD, 1);
      check_mem_value('h08C, exp_value);

      $display("");

      // Non-Pipelined 32b AHB Write accesses
      //--------------------------------------------------
      exp_value = rom_inst.mem['h090];

      repeat(10) @(posedge free_clk);
      ahb_write(1, 32'h00400240, 'h12345678, 2);
      check_mem_value('h090, exp_value);

      $display("");

      $display(" ===============================================");
      $display("|               SIMPLE AHB READS                |");
      $display(" ===============================================");

      // Non-Pipelined 8b AHB Read accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      exp_value = rom_inst.mem['h088];
      ahb_read(1, 32'h00400220, exp_value[7:0],     0, 1);
      @(posedge free_clk);
      exp_value = rom_inst.mem['h090];
      ahb_read(1, 32'h00400240, exp_value,          2, 1);

      repeat(5) @(posedge free_clk);
      exp_value = rom_inst.mem['h088];
      ahb_read(1, 32'h00400221, exp_value[15:8],    0, 1);
      @(posedge free_clk);
      exp_value = rom_inst.mem['h090];
      ahb_read(1, 32'h00400240, exp_value,          2, 1);

      repeat(5) @(posedge free_clk);
      exp_value = rom_inst.mem['h088];
      ahb_read(1, 32'h00400222, exp_value[23:16],   0, 1);
      @(posedge free_clk);
      exp_value = rom_inst.mem['h090];
      ahb_read(1, 32'h00400240, exp_value,          2, 1);

      repeat(5) @(posedge free_clk);
      exp_value = rom_inst.mem['h088];
      ahb_read(1, 32'h00400223, exp_value[31:24],   0, 1);
      @(posedge free_clk);
      exp_value = rom_inst.mem['h090];
      ahb_read(1, 32'h00400240, exp_value,          2, 1);

      $display("");

      // Non-Pipelined 16b AHB Read accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      exp_value = rom_inst.mem['h08C];
      ahb_read(1, 32'h00400230, exp_value[15:0],    1, 1);
      @(posedge free_clk);
      exp_value = rom_inst.mem['h088];
      ahb_read(1, 32'h00400220, exp_value,          2, 1);

      repeat(5) @(posedge free_clk);
      exp_value = rom_inst.mem['h08C];
      ahb_read(1, 32'h00400232, exp_value[31:16],   1, 1);
      @(posedge free_clk);
      exp_value = rom_inst.mem['h088];
      ahb_read(1, 32'h00400220, exp_value,          2, 1);

      $display("");

      // Non-Pipelined 32b AHB Read accesses
      //--------------------------------------------------
      repeat(10) @(posedge free_clk);
      exp_value = rom_inst.mem['h090];
      ahb_read(1, 32'h00400240, exp_value,          2, 1);
      @(posedge free_clk);
      exp_value = rom_inst.mem['h08C];
      ahb_read(1, 32'h00400230, exp_value,          2, 1);


      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
