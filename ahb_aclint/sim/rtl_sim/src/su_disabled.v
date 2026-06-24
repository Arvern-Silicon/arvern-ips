//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    su_disabled
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : su_disabled
// Module Description : With SU_MODE_EN=0 the SSWI sub-block is elided : the
//                      0xC000 window is RAZ/WI and irq_s_software_o is tied
//                      low across all NUM_HARTS bits. Sanity-checks that
//                      MSWI is still alive.
//                      Requires SU_MODE_EN = 0.
//----------------------------------------------------------------------------

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|       SU_MODE_EN=0 : SSWI WINDOW RAZ/WI       |");
      $display(" ===============================================");
      $display("INFO:  NUM_HARTS = %0d, SU_MODE_EN = %0d",
               NUM_HARTS, SU_MODE_EN);

      // SSWI base offset reads as 0.
      ahb_read(1, MACHINE, 32'h0040C000, 32'h00000000, 2, 1, OK);
      // Write all-ones; window must drop the write and stay RAZ.
      ahb_write(1, MACHINE, 32'h0040C000, 32'hFFFFFFFF, 2, OK);
      repeat(2) @(posedge free_clk);
      ahb_read(1, MACHINE, 32'h0040C000, 32'h00000000, 2, 1, OK);

      // Off-base offset inside the SSWI window also RAZ/WI.
      ahb_read(1, MACHINE, 32'h0040C004, 32'h00000000, 2, 1, OK);

      // irq_s_software_o is tied 0 across all NUM_HARTS bits.
      if (tb_ahb_aclint.dut.irq_s_software_o !== {NUM_HARTS{1'b0}}) begin
         $display("ERROR: irq_s_software_o expected all-zero (SU disabled) -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_s_software_o, $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_software_o == {NUM_HARTS{1'b0}} (SU disabled) %t ns", $time);
      end

      $display(" ===============================================");
      $display("|       SANITY : MSWI / MTIMER STILL ALIVE      |");
      $display(" ===============================================");

      // MSWI must still respond -- write MSIP[0] = 1, check irq_m_software_o[0].
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000001, 2, OK);
      repeat(2) @(posedge free_clk);
      if (tb_ahb_aclint.dut.irq_m_software_o[0] !== 1'b1) begin
         $display("ERROR: irq_m_software_o[0] expected 1 after MSIP[0]=1 -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_m_software_o[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_software_o[0] == 1 (MSWI live with SU disabled) %t ns", $time);
      end

      // Clean up : drop MSIP[0].
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000000, 2, OK);
      repeat(2) @(posedge free_clk);
      if (tb_ahb_aclint.dut.irq_m_software_o[0] !== 1'b0) begin
         $display("ERROR: irq_m_software_o[0] expected 0 at end -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_m_software_o[0], $time);
         error = error + 1;
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
