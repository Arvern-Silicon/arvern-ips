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
// Module Description : Pipelined read/write test stimulus.
//----------------------------------------------------------------------------

integer ii;
integer jj;
integer kk;
integer ahb_master;
integer allow_peripheral_accesses;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      ahb_master = 0;
`ifdef FUSED
      // FUSED: M0 -> Port A is read-only (instruction fetch only); skip M0 writes.
      for (ahb_master=1; ahb_master < 3; ahb_master=ahb_master+1)
`else
      for (ahb_master=0; ahb_master < 3; ahb_master=ahb_master+1)
`endif
         begin
            $display("");
            $display("================================================================================================================================================");
            $display("================================================================================================================================================");
            $display("================================================================================================================================================");
            $display("================================================================================================================================================");
            $display("");

            allow_peripheral_accesses = 1;
            `ifdef HIPERF
               if (ahb_master == 0)
                  allow_peripheral_accesses = 0;
            `endif

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


            $display(" ====================================================================");
            $display("|     DEFAULT SLAVE: AHB ERROR RESPONSE -- AHB MASTER %d    |", ahb_master);
            $display(" ====================================================================");

            repeat(10) @(posedge free_clk);
            ahb_write(ahb_master, 1, 32'h00500000, 'hCAFEC00F, 2);

            $display("");

            $display(" ====================================================================");
            $display("|        PIPELINED 32B AHB READ/WRITES  -- AHB MASTER %d    |", ahb_master);
            $display(" ====================================================================");

            repeat(10) @(posedge free_clk);
            for (ii = 0; ii < 8; ii = ii + 1) begin

               repeat(10) @(posedge free_clk);                                   // Accessing the ROM
               jj = rom_inst0.mem[ii];
               ahb_write(ahb_master, 0, 32'h00400000+(ii*4), 32'hDEADBEEF,          2   );
               ahb_read( ahb_master, 0, 32'h00400000+(ii*4), jj[7:0],               0, 1);
               ahb_read( ahb_master, 0, 32'h00400001+(ii*4), jj[15:8],              0, 1);
               ahb_read( ahb_master, 0, 32'h00400002+(ii*4), jj[23:16],             0, 1);
               ahb_read( ahb_master, 0, 32'h00400003+(ii*4), jj[31:24],             0, 1);
               ahb_read( ahb_master, 0, 32'h00400000+(ii*4), jj[15:0],              1, 1);
               ahb_read( ahb_master, 0, 32'h00400002+(ii*4), jj[31:16],             1, 1);
               ahb_read( ahb_master, 1, 32'h00400000+(ii*4), jj[31:0],              2, 1);
               check_rom_value( ii,                 jj[31:0]);
               $display("");

               repeat(5) @(posedge free_clk);                                   // Accessing the SRAM
               jj = $urandom;
               ahb_write(ahb_master, 0, 32'h00401000+(ii*4), jj[31:0],              2   );
               ahb_read( ahb_master, 0, 32'h00401000+(ii*4), jj[7:0],               0, 1);
               ahb_read( ahb_master, 0, 32'h00401001+(ii*4), jj[15:8],              0, 1);
               ahb_read( ahb_master, 0, 32'h00401002+(ii*4), jj[23:16],             0, 1);
               ahb_read( ahb_master, 0, 32'h00401003+(ii*4), jj[31:24],             0, 1);
               ahb_read( ahb_master, 0, 32'h00401000+(ii*4), jj[15:0],              1, 1);
               ahb_read( ahb_master, 0, 32'h00401002+(ii*4), jj[31:16],             1, 1);
               ahb_read( ahb_master, 1, 32'h00401000+(ii*4), jj[31:0],              2, 1);
               check_mem_value( ii,                 jj[31:0]);
               $display("");

               if (allow_peripheral_accesses) begin

                  repeat(5) @(posedge free_clk);                                   // Accessing the PERIPHERAL #0
                  jj = $urandom;
                  ahb_write(ahb_master, 0, 32'h00402000+(ii*4), jj[31:0],              2   );
                  ahb_read( ahb_master, 0, 32'h00402000+(ii*4), jj[7:0],               0, 1);
                  ahb_read( ahb_master, 0, 32'h00402001+(ii*4), jj[15:8],              0, 1);
                  ahb_read( ahb_master, 0, 32'h00402002+(ii*4), jj[23:16],             0, 1);
                  ahb_read( ahb_master, 0, 32'h00402003+(ii*4), jj[31:24],             0, 1);
                  ahb_read( ahb_master, 0, 32'h00402000+(ii*4), jj[15:0],              1, 1);
                  ahb_read( ahb_master, 0, 32'h00402002+(ii*4), jj[31:16],             1, 1);
                  ahb_read( ahb_master, 1, 32'h00402000+(ii*4), jj[31:0],              2, 1);
                  check_periph_reg_value(0, ii,        jj[31:0]                   );
                  $display("");

                  repeat(5) @(posedge free_clk);                                   // Accessing the PERIPHERAL #1
                  jj = $urandom;
                  ahb_write(ahb_master, 0, 32'h00403000+(ii*4), jj[31:0],              2   );
                  ahb_read( ahb_master, 0, 32'h00403000+(ii*4), jj[7:0],               0, 1);
                  ahb_read( ahb_master, 0, 32'h00403001+(ii*4), jj[15:8],              0, 1);
                  ahb_read( ahb_master, 0, 32'h00403002+(ii*4), jj[23:16],             0, 1);
                  ahb_read( ahb_master, 0, 32'h00403003+(ii*4), jj[31:24],             0, 1);
                  ahb_read( ahb_master, 0, 32'h00403000+(ii*4), jj[15:0],              1, 1);
                  ahb_read( ahb_master, 0, 32'h00403002+(ii*4), jj[31:16],             1, 1);
                  ahb_read( ahb_master, 1, 32'h00403000+(ii*4), jj[31:0],              2, 1);
                  check_periph_reg_value(1, ii,        jj[31:0]                   );
                  $display("");
               end
            end
            $display("");

            $display(" ====================================================================");
            $display("|        PIPELINED 16B AHB READ/WRITES  -- AHB MASTER %d    |", ahb_master);
            $display(" ====================================================================");

            repeat(10) @(posedge free_clk);
            for (ii = 0; ii < 8; ii = ii + 1) begin

               repeat(10) @(posedge free_clk);                                   // Accessing the ROM
               jj = rom_inst0.mem[ii];
               ahb_write(ahb_master, 0, 32'h00400000+(ii*4), 'hBEEF,                1   );
               ahb_read( ahb_master, 0, 32'h00400000+(ii*4), jj[7:0],               0, 1);
               ahb_read( ahb_master, 0, 32'h00400001+(ii*4), jj[15:8],              0, 1);
               ahb_read( ahb_master, 0, 32'h00400002+(ii*4), jj[23:16],             0, 1);
               ahb_read( ahb_master, 0, 32'h00400003+(ii*4), jj[31:24],             0, 1);
               ahb_read( ahb_master, 0, 32'h00400000+(ii*4), jj[15:0],              1, 1);
               ahb_read( ahb_master, 0, 32'h00400002+(ii*4), jj[31:16],             1, 1);
               ahb_read( ahb_master, 1, 32'h00400000+(ii*4), jj[31:0],              2, 1);
               check_rom_value( ii,                 jj[31:0]);
               $display("");
               ahb_write(ahb_master, 0, 32'h00400002+(ii*4), 'hDEAD,                1   );
               ahb_read( ahb_master, 0, 32'h00400000+(ii*4), jj[7:0],               0, 1);
               ahb_read( ahb_master, 0, 32'h00400001+(ii*4), jj[15:8],              0, 1);
               ahb_read( ahb_master, 0, 32'h00400002+(ii*4), jj[23:16],             0, 1);
               ahb_read( ahb_master, 0, 32'h00400003+(ii*4), jj[31:24],             0, 1);
               ahb_read( ahb_master, 0, 32'h00400000+(ii*4), jj[15:0],              1, 1);
               ahb_read( ahb_master, 0, 32'h00400002+(ii*4), jj[31:16],             1, 1);
               ahb_read( ahb_master, 1, 32'h00400000+(ii*4), jj[31:0],              2, 1);
               check_rom_value( ii,                 jj[31:0]);
               $display("");

               repeat(5) @(posedge free_clk);                                   // Accessing the SRAM
               jj = $urandom;
               ahb_write(ahb_master, 0, 32'h00401100+(ii*4), jj[15:0],              1   );
               ahb_read( ahb_master, 0, 32'h00401100+(ii*4), jj[7:0],               0, 1);
               ahb_read( ahb_master, 0, 32'h00401101+(ii*4), jj[15:8],              0, 1);
               ahb_read( ahb_master, 0, 32'h00401102+(ii*4), 'h00,                  0, 1);
               ahb_read( ahb_master, 0, 32'h00401103+(ii*4), 'h00,                  0, 1);
               ahb_read( ahb_master, 0, 32'h00401100+(ii*4), jj[15:0],              1, 1);
               ahb_read( ahb_master, 0, 32'h00401102+(ii*4), 'h0000,                1, 1);
               ahb_read( ahb_master, 1, 32'h00401100+(ii*4), {16'h0000, jj[15:0]},  2, 1);
               check_mem_value(64+ii,               {16'h0000, jj[15:0]});
               $display("");
               ahb_write(ahb_master, 0, 32'h00401202+(ii*4), jj[31:16],             1   );
               ahb_read( ahb_master, 0, 32'h00401200+(ii*4), 'h00,                  0, 1);
               ahb_read( ahb_master, 0, 32'h00401201+(ii*4), 'h00,                  0, 1);
               ahb_read( ahb_master, 0, 32'h00401202+(ii*4), jj[23:16],             0, 1);
               ahb_read( ahb_master, 0, 32'h00401203+(ii*4), jj[31:24],             0, 1);
               ahb_read( ahb_master, 0, 32'h00401200+(ii*4), 'h0000,                1, 1);
               ahb_read( ahb_master, 0, 32'h00401202+(ii*4), jj[31:16],             1, 1);
               ahb_read( ahb_master, 1, 32'h00401200+(ii*4), {jj[31:16], 16'h0000}, 2, 1);
               check_mem_value(128+ii,              {jj[31:16], 16'h0000});
               $display("");

               if (allow_peripheral_accesses) begin

                  repeat(5) @(posedge free_clk);                                   // Accessing the PERIPHERAL #0
                  kk = $urandom;
                  ahb_write(ahb_master, 0, 32'h00402000+(ii*4), kk[31:0],              2   );
                  jj = $urandom;
                  ahb_write(ahb_master, 0, 32'h00402000+(ii*4), jj[15:0],              1   );
                  ahb_read( ahb_master, 0, 32'h00402000+(ii*4), jj[7:0],               0, 1);
                  ahb_read( ahb_master, 0, 32'h00402001+(ii*4), jj[15:8],              0, 1);
                  ahb_read( ahb_master, 0, 32'h00402002+(ii*4), kk[23:16],             0, 1);
                  ahb_read( ahb_master, 0, 32'h00402003+(ii*4), kk[31:24],             0, 1);
                  ahb_read( ahb_master, 0, 32'h00402000+(ii*4), jj[15:0],              1, 1);
                  ahb_read( ahb_master, 0, 32'h00402002+(ii*4), kk[31:16],             1, 1);
                  ahb_read( ahb_master, 1, 32'h00402000+(ii*4), {kk[31:16], jj[15:0]}, 2, 1);
                  check_periph_reg_value(0, ii,        {kk[31:16], jj[15:0]}      );
                  $display("");
                  kk = $urandom;
                  ahb_write(ahb_master, 0, 32'h00402002+(ii*4), kk[15:0],              1   );
                  ahb_read( ahb_master, 0, 32'h00402000+(ii*4), jj[7:0],               0, 1);
                  ahb_read( ahb_master, 0, 32'h00402001+(ii*4), jj[15:8],              0, 1);
                  ahb_read( ahb_master, 0, 32'h00402002+(ii*4), kk[7:0],               0, 1);
                  ahb_read( ahb_master, 0, 32'h00402003+(ii*4), kk[15:8],              0, 1);
                  ahb_read( ahb_master, 0, 32'h00402000+(ii*4), jj[15:0],              1, 1);
                  ahb_read( ahb_master, 0, 32'h00402002+(ii*4), kk[15:0],              1, 1);
                  ahb_read( ahb_master, 1, 32'h00402000+(ii*4), {kk[15:0], jj[15:0]},  2, 1);
                  check_periph_reg_value(0, ii,        {kk[15:0], jj[15:0]}       );
                  $display("");

                  repeat(5) @(posedge free_clk);                                   // Accessing the PERIPHERAL #1
                  kk = $urandom;
                  ahb_write(ahb_master, 0, 32'h00403000+(ii*4), kk[31:0],              2   );
                  jj = $urandom;
                  ahb_write(ahb_master, 0, 32'h00403000+(ii*4), jj[15:0],              1   );
                  ahb_read( ahb_master, 0, 32'h00403000+(ii*4), jj[7:0],               0, 1);
                  ahb_read( ahb_master, 0, 32'h00403001+(ii*4), jj[15:8],              0, 1);
                  ahb_read( ahb_master, 0, 32'h00403002+(ii*4), kk[23:16],             0, 1);
                  ahb_read( ahb_master, 0, 32'h00403003+(ii*4), kk[31:24],             0, 1);
                  ahb_read( ahb_master, 0, 32'h00403000+(ii*4), jj[15:0],              1, 1);
                  ahb_read( ahb_master, 0, 32'h00403002+(ii*4), kk[31:16],             1, 1);
                  ahb_read( ahb_master, 1, 32'h00403000+(ii*4), {kk[31:16], jj[15:0]}, 2, 1);
                  check_periph_reg_value(1, ii,        {kk[31:16], jj[15:0]}      );
                  $display("");
                  kk = $urandom;
                  ahb_write(ahb_master, 0, 32'h00403002+(ii*4), kk[15:0],              1   );
                  ahb_read( ahb_master, 0, 32'h00403000+(ii*4), jj[7:0],               0, 1);
                  ahb_read( ahb_master, 0, 32'h00403001+(ii*4), jj[15:8],              0, 1);
                  ahb_read( ahb_master, 0, 32'h00403002+(ii*4), kk[7:0],               0, 1);
                  ahb_read( ahb_master, 0, 32'h00403003+(ii*4), kk[15:8],              0, 1);
                  ahb_read( ahb_master, 0, 32'h00403000+(ii*4), jj[15:0],              1, 1);
                  ahb_read( ahb_master, 0, 32'h00403002+(ii*4), kk[15:0],              1, 1);
                  ahb_read( ahb_master, 1, 32'h00403000+(ii*4), {kk[15:0], jj[15:0]},  2, 1);
                  check_periph_reg_value(1, ii,        {kk[15:0], jj[15:0]}       );
                  $display("");
               end
            end
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
