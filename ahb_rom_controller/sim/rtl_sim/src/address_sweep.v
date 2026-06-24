//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    address_sweep
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : address_sweep.v
// Module Description : Reads every word in the ROM via pipelined NONSEQ
//                      transfers, verifying full address-space coverage and
//                      that the AHB pipeline holds for an arbitrary burst
//                      length.
//----------------------------------------------------------------------------

integer    ii;
reg [31:0] exp_value;

initial
   begin
      // Initialise the entire ROM with random values.
      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
        rom_inst.mem[tb_idx] = $urandom;

      @(posedge free_clk);
      @(posedge hresetn);

      $display(" ===============================================");
      $display("|              ADDRESS SWEEP READ               |");
      $display(" ===============================================");

      repeat(10) @(posedge free_clk);

      // Sweep every 32-bit word in the ROM. All but the last are
      // non-blocking so the calls produce a continuous pipelined burst;
      // the last call blocks to flush the DPH before end-of-test.
      for (ii = 0; ii < (MEM_SIZE/4); ii = ii + 1) begin
         exp_value = rom_inst.mem[ii];
         if (ii == ((MEM_SIZE/4) - 1)) begin
            ahb_read(1, 32'h00400000 + (ii*4), exp_value, 2, 1);
         end else begin
            ahb_read(0, 32'h00400000 + (ii*4), exp_value, 2, 1);
         end
      end

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
