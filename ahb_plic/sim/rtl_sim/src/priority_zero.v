//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    priority_zero
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : priority_zero
// Module Description : Priority 0 = "never interrupt" (RISC-V PLIC 1.0 Ch.4).
//                      The `prio != 0` term (plic_target.v:139) gates BOTH the
//                      irq and the claim winner. No existing test leaves a
//                      pending+enabled source at priority 0 and checks it stays
//                      quiet -- every test writes a non-zero priority first. A
//                      bug that let priority-0 sources qualify would pass the
//                      whole suite. This exercises that dedicated term.
//----------------------------------------------------------------------------

`define PLIC_BASE     32'h00400000
`define PRIO_BASE     32'h00000000
`define ENABLE_BASE   32'h00002000
`define TARGET_BASE   32'h00200000

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|     PLIC : PRIORITY 0 = NEVER INTERRUPT       |");
      $display(" ===============================================");

      // Enable source 5 for ctx 0, threshold 0, but leave priority[5] = 0.
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0, 32'h0000_0020, 2, OK); // bit 5
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0, 32'd0, 2, OK);         // threshold 0

      // Assert the source. priority is 0 -> must NOT interrupt and must NOT win a claim.
      irq_src[5] = 1'b1;
      repeat(4) @(posedge free_clk);

      if (irq_m_external[0] !== 1'b0) begin
         $display("ERROR: irq_m_external_o[0] asserted for a priority-0 source %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  priority-0 source did not raise irq %t ns", $time);
      end

      // Claim read must return 0 (no qualifying source).
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd0, 2, 1, OK);
      $display("PASS:  claim returned 0 for a priority-0 source %t ns", $time);

      // Now raise priority[5] to 1 -> it must immediately qualify.
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*5, 32'd1, 2, OK);
      repeat(4) @(posedge free_clk);

      if (irq_m_external[0] !== 1'b1) begin
         $display("ERROR: irq_m_external_o[0] did not assert after priority raised to 1 %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  raising priority above 0 made the source interrupt %t ns", $time);
      end
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd5, 2, 1, OK);

      irq_src[5] = 1'b0;
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
