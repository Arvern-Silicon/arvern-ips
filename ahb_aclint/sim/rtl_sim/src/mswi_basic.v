//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mswi_basic
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mswi_basic.v
// Module Description : Exercise the MSWI register bank (MSIP[0]) and verify
//                      that irq_m_software_o tracks bit[0] of the register
//                      and that bits [31:1] are RAZ.
//----------------------------------------------------------------------------

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|              MSWI : BASIC ACCESS              |");
      $display(" ===============================================");

      // Set MSIP[0]
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000001, 2, OK);
      repeat(2) @(posedge free_clk);
      if (tb_ahb_aclint.dut.irq_m_software_o !== 1'b1) begin
         $display("ERROR: irq_m_software_o expected 1 after MSIP[0]=1 -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_m_software_o, $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_software_o == 1 after MSIP[0]=1 %t ns", $time);
      end

      // Read back MSIP[0] - expect 0x00000001
      ahb_read(1, MACHINE, 32'h00400000, 32'h00000001, 2, 1, OK);

      // Clear MSIP[0]
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000000, 2, OK);
      repeat(2) @(posedge free_clk);
      if (tb_ahb_aclint.dut.irq_m_software_o !== 1'b0) begin
         $display("ERROR: irq_m_software_o expected 0 after MSIP[0]=0 -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_m_software_o, $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_software_o == 0 after MSIP[0]=0 %t ns", $time);
      end

      // Reserved-bits RAZ: write all 1s, bit[0] should latch, [31:1] read 0.
      ahb_write(1, MACHINE, 32'h00400000, 32'hFFFFFFFF, 2, OK);
      repeat(2) @(posedge free_clk);
      if (tb_ahb_aclint.dut.irq_m_software_o !== 1'b1) begin
         $display("ERROR: irq_m_software_o expected 1 after MSIP[0]=0xFFFFFFFF -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_m_software_o, $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_software_o == 1 after MSIP[0]=0xFFFFFFFF %t ns", $time);
      end
      ahb_read(1, MACHINE, 32'h00400000, 32'h00000001, 2, 1, OK);

      // Out-of-window MSIP read (NUM_HARTS=1 - 0x0004 is reserved RAZ/WI).
      ahb_read(1, MACHINE, 32'h00400004, 32'h00000000, 2, 1, OK);

      // Clear and confirm
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000000, 2, OK);
      repeat(2) @(posedge free_clk);
      if (tb_ahb_aclint.dut.irq_m_software_o !== 1'b0) begin
         $display("ERROR: irq_m_software_o expected 0 at end-of-test -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_m_software_o, $time);
         error = error + 1;
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
