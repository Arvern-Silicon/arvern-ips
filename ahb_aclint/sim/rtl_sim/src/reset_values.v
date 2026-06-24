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
//                      existing test reads a register's reset value before
//                      programming it, so a wrong reset value (e.g. MTIMECMP
//                      not all-ones -> spurious boot MTIP, or MSIP/SETSSIP not
//                      cleared -> spurious boot IRQ) would be invisible. This
//                      reads each register cold and asserts the reset value,
//                      and that no interrupt output is asserted at boot.
//                      MTIMECMP resets to 0xFFFFFFFF specifically so the
//                      comparator cannot match before firmware programs it.
//----------------------------------------------------------------------------

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(10) @(posedge free_clk);

      $display(" ===============================================");
      $display("|          POST-RESET REGISTER VALUES           |");
      $display(" ===============================================");

      // MSIP[0] resets to 0.
      ahb_read(1, MACHINE, 32'h00400000, 32'h00000000, 2, 1, OK);

      // MTIMECMP[0] resets to all-ones (prevents a boot-time comparator match).
      ahb_read(1, MACHINE, 32'h00404000, 32'hFFFFFFFF, 2, 1, OK);
      ahb_read(1, MACHINE, 32'h00404004, 32'hFFFFFFFF, 2, 1, OK);

      // SETSSIP[0] reads as 0 (RAZ) out of reset.
      ahb_read(1, MACHINE, 32'h0040C000, 32'h00000000, 2, 1, OK);

      // No interrupt output may be asserted at boot, before any programming.
      if (tb_ahb_aclint.dut.irq_m_software_o[0] !== 1'b0) begin
         $display("ERROR: irq_m_software_o[0] asserted at boot (MSIP not cleared) %t ns", $time);
         error = error + 1;
      end
      if (tb_ahb_aclint.dut.irq_m_timer_o[0] !== 1'b0) begin
         $display("ERROR: irq_m_timer_o[0] asserted at boot (MTIMECMP reset != all-ones?) %t ns", $time);
         error = error + 1;
      end
      if (tb_ahb_aclint.dut.irq_s_software_o[0] !== 1'b0) begin
         $display("ERROR: irq_s_software_o[0] asserted at boot %t ns", $time);
         error = error + 1;
      end
      if (error == 0)
         $display("PASS:  all reset values correct and no boot-time IRQ asserted %t ns", $time);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
