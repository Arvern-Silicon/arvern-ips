//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    simple_arbiter
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : simple_arbiter.v
// Module Description : Simple arbiter test stimulus.
//----------------------------------------------------------------------------

integer ii;
integer jj;
integer m0_dly;
integer m1_dly;
integer m2_dly;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(10) @(posedge free_clk);

      $display("");
      $display(" =====================================================");
      $display("|        SOME SIMPLE ARBITRATIOMS BETWEEN M0/M1/M3    |");
      $display(" =====================================================");
      repeat(10) @(posedge free_clk);

      // Initialiye the ROM with random values
      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
         rom_inst0.mem[tb_idx]  = $urandom;

      // Clear the SRAM
      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
         sram_inst0.mem[tb_idx] = 32'h00000000;

      // Reset the peripherals
      @(negedge free_clk);
      force   ahb_periph_example_inst0.hresetn_i = 1'b0;
      force   ahb_periph_example_inst1.hresetn_i = 1'b0;
      @(negedge free_clk);
      release ahb_periph_example_inst0.hresetn_i;
      release ahb_periph_example_inst1.hresetn_i;

      repeat(10) @(posedge free_clk);

      $display("");

      fork
         begin                                                     // AHB Master 0
            ahb_read( 0, 1, 32'h00400000, rom_inst0.mem[0], 2, 1);
            repeat(15) @(posedge free_clk);
            ahb_write(0, 1, 32'h00401010, 'hCAFEC00F,       2   );
            repeat(15) @(posedge free_clk);
            ahb_write(0, 1, 32'h00402010, 'hDEADBEEF,       2   );
            repeat(15) @(posedge free_clk);
            ahb_write(0, 1, 32'h00403010, 'h12345678,       2   );
            repeat(15) @(posedge free_clk);
            ahb_read( 0, 1, 32'h00403000, 'hB00BAFE1,       2, 1);
            repeat(15) @(posedge free_clk);
            ahb_read( 0, 1, 32'h00402018, 'hF0123456,       2, 1);
            repeat(15) @(posedge free_clk);
            ahb_read( 0, 1, 32'h00401000, 'h9ABCDEF0,       2, 1);
            repeat(15) @(posedge free_clk);
         end
         begin                                                     // AHB Master 1
            ahb_write(1, 1, 32'h00403000, 'hB00BAFE1,       2   );
            repeat(15) @(posedge free_clk);
            ahb_read( 1, 1, 32'h00400004, rom_inst0.mem[1], 2, 1);
            repeat(15) @(posedge free_clk);
            ahb_write(1, 1, 32'h00402000, 'hBAD0BACC,       2   );
            repeat(15) @(posedge free_clk);
            ahb_write(1, 1, 32'h00401000, 'h9ABCDEF0,       2   );
            repeat(15) @(posedge free_clk);
            ahb_read( 1, 1, 32'h00401018, 'hABCDEF01,       2, 1);
            repeat(15) @(posedge free_clk);
            ahb_read( 1, 1, 32'h00402010, 'hDEADBEEF,       2, 1);
            repeat(15) @(posedge free_clk);
            ahb_read( 1, 1, 32'h00403018, 'h456789AB,       2, 1);
            repeat(15) @(posedge free_clk);
         end
         begin                                                     // AHB Master 2
            ahb_write(2, 1, 32'h00401018, 'hABCDEF01,       2   );
            repeat(15) @(posedge free_clk);
            ahb_write(2, 1, 32'h00402018, 'hF0123456,       2   );
            repeat(15) @(posedge free_clk);
            ahb_read( 2, 1, 32'h00400008, rom_inst0.mem[2], 2, 1);
            repeat(15) @(posedge free_clk);
            ahb_write(2, 1, 32'h00403018, 'h456789AB,       2   );
            repeat(15) @(posedge free_clk);
            ahb_read( 2, 1, 32'h00401010, 'hCAFEC00F,       2, 1);
            repeat(15) @(posedge free_clk);
            ahb_read( 2, 1, 32'h00402000, 'hBAD0BACC,       2, 1);
            repeat(15) @(posedge free_clk);
            ahb_read( 2, 1, 32'h00403010, 'h12345678,       2, 1);
            repeat(15) @(posedge free_clk);
         end
      join
      repeat(10) @(posedge free_clk);

      $display("");
      $display(" =====================================================");
      $display("|     SOME PIPELINED ARBITRATIOMS BETWEEN M0/M1/M3    |");
      $display(" =====================================================");
      repeat(10) @(posedge free_clk);

      // Initialiye the ROM with random values
      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
         rom_inst0.mem[tb_idx]  = $urandom;

      // Clear the SRAM
      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
         sram_inst0.mem[tb_idx] = 32'h00000000;

      // Reset the peripherals
      @(negedge free_clk);
      force   ahb_periph_example_inst0.hresetn_i = 1'b0;
      force   ahb_periph_example_inst1.hresetn_i = 1'b0;
      @(negedge free_clk);
      release ahb_periph_example_inst0.hresetn_i;
      release ahb_periph_example_inst1.hresetn_i;

      repeat(10) @(posedge free_clk);

      $display("");
      m0_dly = $urandom % 5;
      m1_dly = $urandom % 5;
      m2_dly = $urandom % 5;

      fork
         begin                                                     // AHB Master 0
            repeat(m0_dly) @(posedge free_clk);
            ahb_read( 0, 0, 32'h00400000, rom_inst0.mem[0], 2, 1);
            ahb_write(0, 0, 32'h00401010, 'hCAFEC00F,       2   );
            ahb_write(0, 0, 32'h00402010, 'hDEADBEEF,       2   );
            ahb_write(0, 0, 32'h00403010, 'h12345678,       2   );
            ahb_read( 0, 0, 32'h0040000C, rom_inst0.mem[3], 2, 1);
            ahb_read( 0, 0, 32'h00400010, rom_inst0.mem[4], 2, 1);
            ahb_read( 0, 0, 32'h00403000, 'hB00BAFE1,       2, 1);
            ahb_read( 0, 0, 32'h00402018, 'hF0123456,       2, 1);
            ahb_read( 0, 0, 32'h00401000, 'h9ABCDEF0,       2, 1);
         end
         begin                                                     // AHB Master 1
            repeat(m1_dly) @(posedge free_clk);
            ahb_write(1, 0, 32'h00403000, 'hB00BAFE1,       2   );
            ahb_read( 1, 0, 32'h00400004, rom_inst0.mem[1], 2, 1);
            ahb_write(1, 0, 32'h00402000, 'hBAD0BACC,       2   );
            ahb_write(1, 0, 32'h00401000, 'h9ABCDEF0,       2   );
            ahb_read( 1, 0, 32'h00400014, rom_inst0.mem[5], 2, 1);
            ahb_read( 1, 0, 32'h00400018, rom_inst0.mem[6], 2, 1);
            ahb_read( 1, 0, 32'h00401018, 'hABCDEF01,       2, 1);
            ahb_read( 1, 0, 32'h00402010, 'hDEADBEEF,       2, 1);
            ahb_read( 1, 0, 32'h00403018, 'h456789AB,       2, 1);
         end
         begin                                                     // AHB Master 2
            repeat(m2_dly) @(posedge free_clk);
            ahb_write(2, 0, 32'h00401018, 'hABCDEF01,       2   );
            ahb_write(2, 0, 32'h00402018, 'hF0123456,       2   );
            ahb_read( 2, 0, 32'h00400008, rom_inst0.mem[2], 2, 1);
            ahb_write(2, 0, 32'h00403018, 'h456789AB,       2   );
            ahb_read( 2, 0, 32'h0040001C, rom_inst0.mem[7], 2, 1);
            ahb_read( 2, 0, 32'h00400020, rom_inst0.mem[8], 2, 1);
            ahb_read( 2, 0, 32'h00401010, 'hCAFEC00F,       2, 1);
            ahb_read( 2, 0, 32'h00402000, 'hBAD0BACC,       2, 1);
            ahb_read( 2, 0, 32'h00403010, 'h12345678,       2, 1);
         end
      join

      repeat(10) @(posedge free_clk);


      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
