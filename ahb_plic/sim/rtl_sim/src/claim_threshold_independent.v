//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Test:      claim_threshold_independent
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// Description: PLIC 1.0.0 Chapter 8 -- "The claim operation is not affected by
//              the setting of the priority threshold register."
//
//   Scenario:
//     priority[5] = 3 (below threshold)
//     priority[7] = 5 (just above threshold)
//     threshold   = 4 (masks sources with priority <= 4)
//     enable[ctx0][5] = enable[ctx0][7] = 1
//     irq_src[5] = irq_src[7] = 1
//
//   Expected:
//     irq_mext_o[0] = 1     (because src 7 has priority 5 > threshold 4)
//     claim @ ctx0  = 7     (highest qualified pri above threshold)
//     -- now lower threshold to 0 and complete; only src 5 remains pending
//     irq_mext_o[0] = 1     (src 5 above threshold 0)
//     -- raise threshold to 6 -- src 5 (pri 3) is now masked
//     irq_mext_o[0] = 0     (no source qualifies for IRQ)
//     BUT claim @ ctx0 STILL returns 5  <-- the spec-compliance assertion.
//     Pre-fix (threshold filtered the claim too): claim would return 0.
//----------------------------------------------------------------------------

// Base of the PLIC slave window (matches hsel decode in the TB).
`define PLIC_BASE        32'h00400000
`define PRIORITY_BASE    32'h00000000
`define ENABLE_BASE      32'h00002000
`define TARGET_BASE      32'h00200000

integer ii;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      tb_ahb_plic.irq_src = {(NUM_SOURCES+1){1'b0}};

      $display(" ===============================================");
      $display("|    SETUP: pri[5]=3, pri[7]=5, en[ctx0]=on     |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `PLIC_BASE + `PRIORITY_BASE + 32'h0014, 32'd3, 2, OK);  // pri[5]
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIORITY_BASE + 32'h001C, 32'd5, 2, OK);  // pri[7]

      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0,
                32'h0000_00A0, 2, OK);                                              // bits 5 + 7 set

      $display(" ===============================================");
      $display("|    THRESHOLD=4 -> src5 MASKED, src7 PASSES    |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0, 32'd4, 2, OK);       // threshold

      tb_ahb_plic.irq_src[5] = 1'b1;
      tb_ahb_plic.irq_src[7] = 1'b1;
      repeat(3) @(posedge free_clk);

      if (tb_ahb_plic.dut.irq_m_external_o[0] !== 1'b1) begin
         $display("ERROR: irq_m_external_o[0] expected 1 (src 7 above threshold) -- got %b %t ns",
                  tb_ahb_plic.dut.irq_m_external_o[0], $time);
         error = error + 1;
      end else
         $display("PASS:  irq_m_external_o[0] == 1 with src7 above threshold %t ns", $time);

      // Read claim/complete @ ctx 0 -- expect source 7 (highest qualifying for IRQ)
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd7, 2, 1, OK);

      // Drop src 7 then complete it so only src 5 remains pending
      tb_ahb_plic.irq_src[7] = 1'b0;
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd7, 2, OK);

      // Now lower threshold to 0 -- src 5 (priority 3) should drive IRQ
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0, 32'd0, 2, OK);
      repeat(3) @(posedge free_clk);

      if (tb_ahb_plic.dut.irq_m_external_o[0] !== 1'b1) begin
         $display("ERROR: irq_m_external_o[0] expected 1 (src 5 above threshold 0) -- got %b %t ns",
                  tb_ahb_plic.dut.irq_m_external_o[0], $time);
         error = error + 1;
      end else
         $display("PASS:  irq_m_external_o[0] == 1 with src5 above threshold 0 %t ns", $time);

      $display(" ===============================================");
      $display("|    THRESHOLD=6 -> src5 MASKED FROM IRQ        |");
      $display("|    BUT CLAIM MUST STILL RETURN 5 (spec Ch 8)  |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0, 32'd6, 2, OK);       // threshold
      repeat(3) @(posedge free_clk);

      // Spec-compliance assertion #1: IRQ output should drop -- src 5 pri 3 <= threshold 6.
      if (tb_ahb_plic.dut.irq_m_external_o[0] !== 1'b0) begin
         $display("ERROR: irq_m_external_o[0] expected 0 with src5 masked by threshold -- got %b %t ns",
                  tb_ahb_plic.dut.irq_m_external_o[0], $time);
         error = error + 1;
      end else
         $display("PASS:  irq_m_external_o[0] == 0 with src5 below threshold %t ns", $time);

      // Spec-compliance assertion #2: claim must STILL return source 5
      // even though threshold masks it from the IRQ line. This is the
      // core fix for PLIC spec Chapter 8 ("claim is not affected by the
      // setting of the priority threshold register"). Pre-fix: this read
      // would return 0.
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd5, 2, 1, OK);

      // Drop the source level + complete to drain
      tb_ahb_plic.irq_src[5] = 1'b0;
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd5, 2, OK);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
