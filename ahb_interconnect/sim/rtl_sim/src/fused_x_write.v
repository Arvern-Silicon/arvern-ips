//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    fused_x_write
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : fused_x_write.v
// Module Description : Fused fabric: a WRITE presented by the executable-side
//                      manager (m_x, instruction fetch) must be answered with
//                      an AHB ERROR and must not touch the memory. The fused
//                      leaves' Port A is read-only; without the diversion to
//                      the X-side default subordinate the write was executed
//                      as a read and answered OKAY (review finding W-07).
//----------------------------------------------------------------------------

localparam SRAM_ADDR = 32'h00401040;             // executable SRAM, word 16
localparam SRAM_WORD = (SRAM_ADDR - 32'h00401000) >> 2;
localparam ROM_ADDR  = 32'h00400040;             // ROM, word 16
localparam OLD_VAL   = 32'h0BAD0BAD;

// ERROR responses seen on the executable manager port
integer m0_err_cnt;
initial m0_err_cnt = 0;
always @(posedge free_clk)
   if (hresetn && m0_hresp && m0_hready) m0_err_cnt = m0_err_cnt + 1;   // 2nd cycle of a 2-cycle ERROR

task expect_m0_error;
   input [8*40:1] what;
   input integer  err_before;
   begin
      if (m0_err_cnt == err_before + 1)
         $display("PASS:  %0s answered with an AHB ERROR", what);
      else begin
         $display("ERROR: %0s: expected one ERROR response on m_x, saw %0d", what, m0_err_cnt - err_before);
         error = error + 1;
      end
   end
endtask

integer errs_before;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(10) @(posedge free_clk);

      $display("");
      $display(" =====================================================");
      $display("|   FUSED: WRITE FROM THE EXECUTABLE MANAGER (m_x)     |");
      $display(" =====================================================");
      repeat(10) @(posedge free_clk);

      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
         rom_inst0.mem[tb_idx]  = 32'hCAFE0000 | tb_idx;
      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
         sram_inst0.mem[tb_idx] = 32'h00000000;
      sram_inst0.mem[SRAM_WORD] = OLD_VAL;

      @(negedge free_clk);
      force   ahb_periph_example_inst0.hresetn_i = 1'b0;
      force   ahb_periph_example_inst1.hresetn_i = 1'b0;
      @(negedge free_clk);
      release ahb_periph_example_inst0.hresetn_i;
      release ahb_periph_example_inst1.hresetn_i;
      repeat(10) @(posedge free_clk);
      $display("");

      // (a) m_x write to executable SRAM: ERROR, memory untouched
      errs_before = m0_err_cnt;
      ahb_write(0, 1, SRAM_ADDR, 32'hC0DEC0DE, 2);
      repeat(4) @(posedge free_clk);
      expect_m0_error("m_x write to SRAM", errs_before);
      check_mem_value(SRAM_WORD, OLD_VAL);
      ahb_read(1, 1, SRAM_ADDR, OLD_VAL, 2, 1);           // Port B still sees the old word

      // (b) m_x write to ROM: ERROR
      errs_before = m0_err_cnt;
      ahb_write(0, 1, ROM_ADDR, 32'hC0DEC0DE, 2);
      repeat(4) @(posedge free_clk);
      expect_m0_error("m_x write to ROM", errs_before);

      // (c) the executable port keeps working afterwards: reads are OKAY and correct
      errs_before = m0_err_cnt;
      ahb_read(0, 1, SRAM_ADDR, OLD_VAL,           2, 1);
      ahb_read(0, 1, ROM_ADDR,  rom_inst0.mem[16], 2, 1);
      repeat(4) @(posedge free_clk);
      if (m0_err_cnt != errs_before) begin
         $display("ERROR: m_x reads after the write errors were not OKAY");
         error = error + 1;
      end else
         $display("PASS:  m_x reads after the write errors are OKAY");

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
