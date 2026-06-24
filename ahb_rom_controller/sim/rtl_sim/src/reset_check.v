//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    reset_check
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : reset_check.v
// Module Description : Verifies post-reset state of the AHB ROM controller
//                      (hreadyout=1, hresp=0, hrdata=0, first read works).
//----------------------------------------------------------------------------

reg [31:0] exp_value;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      $display(" ===============================================");
      $display("|              RESET STATE CHECK                |");
      $display(" ===============================================");

      // Give the controller a few cycles after reset deassertion,
      // then snapshot the always-on AHB outputs.
      // ROM is left at the TB's all-zero default for this part — we are
      // checking the controller's reset state, not the ROM contents.
      repeat(3) @(posedge free_clk);
      #1;

      // hrdata: gated by rd_active. rd_active resets to 0, so hrdata
      // must be all-zero with no active transfer.
      if (hrdata !== 32'h00000000) begin
         $display("ERROR: hrdata not zero after reset (got 0x%h) %t ns", hrdata, $time);
         error = error + 1;
      end else begin
         $display("PASS:  hrdata is 0x%h after reset %t ns", hrdata, $time);
      end

      // hreadyout: hard-wired to 1.
      if (hreadyout !== 1'b1) begin
         $display("ERROR: hreadyout not 1 after reset (got %b) %t ns", hreadyout, $time);
         error = error + 1;
      end else begin
         $display("PASS:  hreadyout is 1 after reset %t ns", $time);
      end

      // hresp: hard-wired to 0 (OKAY).
      if (hresp !== 1'b0) begin
         $display("ERROR: hresp not 0 after reset (got %b) %t ns", hresp, $time);
         error = error + 1;
      end else begin
         $display("PASS:  hresp is 0 after reset %t ns", $time);
      end

      // rom_cen: active-low, expected high (deasserted) when no access.
      if (rom_cen !== 1'b1) begin
         $display("ERROR: rom_cen not 1 (deasserted) after reset (got %b) %t ns", rom_cen, $time);
         error = error + 1;
      end else begin
         $display("PASS:  rom_cen is 1 (deasserted) after reset %t ns", $time);
      end

      // Now write random non-zero values into the ROM (sim-only
      // backdoor) and verify the first read after reset returns the
      // correct random word — proves the read path is functional and
      // wasn't just "0 == 0" tautologically.
      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
        rom_inst.mem[tb_idx] = $urandom;

      repeat(10) @(posedge free_clk);
      exp_value = rom_inst.mem['h000];
      ahb_read(1, 32'h00400000, exp_value, 2, 1);

      // A second read to a non-zero address — make sure the controller
      // can transition out of the post-reset state and back to idle.
      repeat(5) @(posedge free_clk);
      exp_value = rom_inst.mem['h040];
      ahb_read(1, 32'h00400100, exp_value, 2, 1);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
