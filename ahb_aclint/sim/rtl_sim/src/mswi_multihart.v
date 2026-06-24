//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mswi_multihart
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mswi_multihart
// Module Description : Per-hart MSIP independence and per-hart IRQ routing.
//                      Iterates 0..NUM_HARTS-1, sets each MSIP[h] in turn,
//                      verifies irq_m_software_o[h] tracks bit[0], clears,
//                      then drives a multi-hart simultaneous-pending scenario
//                      and clears in reverse order to confirm independence.
//                      Requires NUM_HARTS >= 2.
//----------------------------------------------------------------------------

integer ii;
integer last_hart;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|         MSWI : PER-HART MSIP SWEEP            |");
      $display(" ===============================================");
      $display("INFO:  NUM_HARTS = %0d", NUM_HARTS);

      // Per-hart independence : set MSIP[h]=1, check irq_m_software_o[h]=1,
      // read-back, clear, check irq drops.
      for (ii = 0; ii < NUM_HARTS; ii = ii + 1) begin
         // Set MSIP[ii] = 1.
         ahb_write(1, MACHINE, 32'h00400000 + (32'h4 * ii), 32'h00000001, 2, OK);
         repeat(2) @(posedge free_clk);
         if (tb_ahb_aclint.dut.irq_m_software_o[ii] !== 1'b1) begin
            $display("ERROR: irq_m_software_o[%0d] expected 1 after MSIP[%0d]=1 -- got %b %t ns",
                     ii, ii, tb_ahb_aclint.dut.irq_m_software_o[ii], $time);
            error = error + 1;
         end else begin
            $display("PASS:  irq_m_software_o[%0d] == 1 after MSIP[%0d]=1 %t ns", ii, ii, $time);
         end

         // Read-back bit[0] = 1.
         ahb_read(1, MACHINE, 32'h00400000 + (32'h4 * ii), 32'h00000001, 2, 1, OK);

         // Clear MSIP[ii].
         ahb_write(1, MACHINE, 32'h00400000 + (32'h4 * ii), 32'h00000000, 2, OK);
         repeat(2) @(posedge free_clk);
         if (tb_ahb_aclint.dut.irq_m_software_o[ii] !== 1'b0) begin
            $display("ERROR: irq_m_software_o[%0d] expected 0 after MSIP[%0d]=0 -- got %b %t ns",
                     ii, ii, tb_ahb_aclint.dut.irq_m_software_o[ii], $time);
            error = error + 1;
         end else begin
            $display("PASS:  irq_m_software_o[%0d] == 0 after MSIP[%0d]=0 %t ns", ii, ii, $time);
         end
      end

      $display(" ===============================================");
      $display("|     MSWI : SIMULTANEOUS PENDING SCENARIO      |");
      $display(" ===============================================");

      // Set MSIP[0], MSIP[1], MSIP[NUM_HARTS-1] simultaneously.
      last_hart = NUM_HARTS - 1;
      ahb_write(1, MACHINE, 32'h00400000,                       32'h00000001, 2, OK);
      ahb_write(1, MACHINE, 32'h00400000 + (32'h4 * 1),         32'h00000001, 2, OK);
      ahb_write(1, MACHINE, 32'h00400000 + (32'h4 * last_hart), 32'h00000001, 2, OK);
      repeat(4) @(posedge free_clk);

      if (tb_ahb_aclint.dut.irq_m_software_o[0] !== 1'b1) begin
         $display("ERROR: irq_m_software_o[0] expected 1 (multi-set) -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_m_software_o[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_software_o[0] == 1 in multi-set scenario %t ns", $time);
      end

      if (tb_ahb_aclint.dut.irq_m_software_o[1] !== 1'b1) begin
         $display("ERROR: irq_m_software_o[1] expected 1 (multi-set) -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_m_software_o[1], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_software_o[1] == 1 in multi-set scenario %t ns", $time);
      end

      if (tb_ahb_aclint.dut.irq_m_software_o[last_hart] !== 1'b1) begin
         $display("ERROR: irq_m_software_o[%0d] expected 1 (multi-set) -- got %b %t ns",
                  last_hart, tb_ahb_aclint.dut.irq_m_software_o[last_hart], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_software_o[%0d] == 1 in multi-set scenario %t ns", last_hart, $time);
      end

      // Clear in reverse order : last_hart, then 1, then 0. After each clear,
      // verify the cleared bit drops and the still-pending bits stay asserted.
      ahb_write(1, MACHINE, 32'h00400000 + (32'h4 * last_hart), 32'h00000000, 2, OK);
      repeat(2) @(posedge free_clk);
      if (tb_ahb_aclint.dut.irq_m_software_o[last_hart] !== 1'b0) begin
         $display("ERROR: irq_m_software_o[%0d] expected 0 after reverse-clear -- got %b %t ns",
                  last_hart, tb_ahb_aclint.dut.irq_m_software_o[last_hart], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_software_o[%0d] cleared independently %t ns", last_hart, $time);
      end
      // At NUM_HARTS=2, last_hart==1 - we just cleared MSIP[1]; only MSIP[0]
      // remains pending. For NUM_HARTS>2, both MSIP[0] and MSIP[1] should
      // still be asserted after the reverse-clear of MSIP[last_hart].
      if (last_hart > 1) begin
         if (tb_ahb_aclint.dut.irq_m_software_o[0] !== 1'b1 ||
             tb_ahb_aclint.dut.irq_m_software_o[1] !== 1'b1) begin
            $display("ERROR: clearing MSIP[%0d] disturbed MSIP[0]/MSIP[1] -- {0,1}={%b,%b} %t ns",
                     last_hart,
                     tb_ahb_aclint.dut.irq_m_software_o[0],
                     tb_ahb_aclint.dut.irq_m_software_o[1], $time);
            error = error + 1;
         end else begin
            $display("PASS:  MSIP[0]/MSIP[1] preserved after clearing MSIP[%0d] %t ns", last_hart, $time);
         end
      end else begin
         if (tb_ahb_aclint.dut.irq_m_software_o[0] !== 1'b1) begin
            $display("ERROR: clearing MSIP[%0d] disturbed MSIP[0] -- got %b %t ns",
                     last_hart, tb_ahb_aclint.dut.irq_m_software_o[0], $time);
            error = error + 1;
         end else begin
            $display("PASS:  MSIP[0] preserved after clearing MSIP[%0d] %t ns", last_hart, $time);
         end
      end

      ahb_write(1, MACHINE, 32'h00400000 + (32'h4 * 1), 32'h00000000, 2, OK);
      repeat(2) @(posedge free_clk);
      if (tb_ahb_aclint.dut.irq_m_software_o[1] !== 1'b0) begin
         $display("ERROR: irq_m_software_o[1] expected 0 after clear -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_m_software_o[1], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_software_o[1] cleared independently %t ns", $time);
      end
      if (tb_ahb_aclint.dut.irq_m_software_o[0] !== 1'b1) begin
         $display("ERROR: clearing MSIP[1] disturbed MSIP[0] -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_m_software_o[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  MSIP[0] preserved after clearing MSIP[1] %t ns", $time);
      end

      ahb_write(1, MACHINE, 32'h00400000, 32'h00000000, 2, OK);
      repeat(2) @(posedge free_clk);
      if (tb_ahb_aclint.dut.irq_m_software_o[0] !== 1'b0) begin
         $display("ERROR: irq_m_software_o[0] expected 0 at end -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_m_software_o[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_software_o[0] cleared at end-of-test %t ns", $time);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
