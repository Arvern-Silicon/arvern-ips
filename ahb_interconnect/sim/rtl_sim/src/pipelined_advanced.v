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
// Module Description : Advanced pipelined test stimulus.
//----------------------------------------------------------------------------

integer ii;
integer jj;
integer ahb_master;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      ahb_master = 1;
      for (ahb_master=1; ahb_master < 3; ahb_master=ahb_master+1)
         begin
            $display("");
            $display("================================================================================================================================================");
            $display("================================================================================================================================================");
            $display("================================================================================================================================================");
            $display("================================================================================================================================================");
            $display("");

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

            $display("");
            $display(" ====================================================================");
            $display("|        PIPELINED 32B AHB READ/WRITES  -- AHB MASTER %d    |", ahb_master);
            $display(" ====================================================================");
            repeat(10) @(posedge free_clk);
            ahb_write(ahb_master, 1, 32'h00400260, 'h13243546, 2);

            $display("");

            // Do some piplelined AHB write-reads accross different AHB subordinates
            ahb_write(ahb_master, 0, 32'h00401010, 'hCAFEC00F, 2);
            ahb_read( ahb_master, 0, 32'h00401010, 'hCAFEC00F, 2, 1);
            ahb_write(ahb_master, 0, 32'h00401014, 'hDEADBEEF, 2);
            ahb_write(ahb_master, 0, 32'h00402000, 'hB00BAFE1, 2);
            ahb_write(ahb_master, 0, 32'h0040101C, 'hACBDBEDF, 2);
            ahb_write(ahb_master, 0, 32'h00403004, 'h12345678, 2);
            ahb_read( ahb_master, 0, 32'h00400010, rom_inst0.mem[4], 2, 1);
            ahb_read( ahb_master, 0, 32'h00401010, 'hCAFEC00F, 2, 1);
            ahb_write(ahb_master, 0, 32'h00401018, 'hBAD0BACC, 2);
            ahb_read( ahb_master, 0, 32'h00400014, rom_inst0.mem[5], 2, 1);
            ahb_read( ahb_master, 0, 32'h00403004, 'h12345678, 2, 1);
            ahb_read( ahb_master, 0, 32'h00401014, 'hDEADBEEF, 2, 1);
            ahb_read( ahb_master, 0, 32'h00402000, 'hB00BAFE1, 2, 1);
            ahb_read( ahb_master, 1, 32'h0040101C, 'hACBDBEDF, 2, 1);

            $display("");
            repeat(10) @(posedge free_clk);
         end

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end

