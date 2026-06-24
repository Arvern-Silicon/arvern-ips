//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    reset_values
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : reset_values
// Module Description : Post-reset register values, read BEFORE any write. No
//                      existing test reads reset values first, so a wrong reset
//                      (e.g. an enable or priority not cleared -> spurious boot
//                      interrupt) would be invisible. All PLIC registers reset
//                      to 0; no external interrupt may be asserted at boot.
//----------------------------------------------------------------------------

`define PLIC_BASE     32'h00400000
`define PRIO_BASE     32'h00000000
`define PENDING_BASE  32'h00001000
`define ENABLE_BASE   32'h00002000
`define TARGET_BASE   32'h00200000

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(6) @(posedge free_clk);

      $display(" ===============================================");
      $display("|          PLIC : POST-RESET REGISTER VALUES    |");
      $display(" ===============================================");

      // Priority regs (sources 1..3) reset to 0.
      ahb_read(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*1, 32'd0, 2, 1, OK);
      ahb_read(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*2, 32'd0, 2, 1, OK);
      ahb_read(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*3, 32'd0, 2, 1, OK);

      // Enable word 0 (ctx 0) resets to 0.
      ahb_read(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0, 32'd0, 2, 1, OK);

      // Pending word 0 resets to 0.
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 32'h0, 32'd0, 2, 1, OK);

      // Threshold (ctx 0) and claim (nothing pending) read 0.
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0, 32'd0, 2, 1, OK);
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd0, 2, 1, OK);

      // No external interrupt may be asserted at boot.
      if (|irq_m_external !== 1'b0) begin
         $display("ERROR: irq_m_external asserted at boot (%b) %t ns", irq_m_external, $time);
         error = error + 1;
      end
      if (|irq_s_external !== 1'b0) begin
         $display("ERROR: irq_s_external asserted at boot (%b) %t ns", irq_s_external, $time);
         error = error + 1;
      end
      if (error == 0)
         $display("PASS:  all reset values 0 and no boot-time interrupt %t ns", $time);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
