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

      $display("");
      $display(" ===============================================");
      $display("|   RESET WITH A NON-COMPLIANT SoC ICG          |");
      $display(" ===============================================");

      // The property: the block must come out of reset and be a working slave
      // even when the SoC's ICG gates purely on hclk_en_o, without the
      // `| ~hresetn_i` term the integration guide asks for.
      //
      // WHAT THIS DOES AND DOES NOT GUARD. It passes whether or not hclk_en_o
      // includes ~hresetn_i, because aph_valid is combinational from the AHB
      // inputs -- so an access raises the enable regardless of flop state, and
      // there is no reachable deadlock to catch. The check pins the PROPERTY,
      // which is worth pinning; it is not a guard on that one term, and nobody
      // should read a pass here as proving the term is doing something.
      icg_ignore_reset = 1'b1;
      @(posedge free_clk);

      hresetn = 1'b0;
      repeat(`LF_CYCLES(2)) @(posedge free_clk);
      hresetn = 1'b1;
      repeat(`LF_CYCLES(5)) @(posedge free_clk);

      // If the clock never ran, these read back X (or the pre-reset value).
      ahb_read(1, MACHINE, 32'h00400000, 32'h00000000, 2, 1, OK);
      ahb_read(1, MACHINE, 32'h00404000, 32'hFFFFFFFF, 2, 1, OK);
      ahb_read(1, MACHINE, 32'h00404004, 32'hFFFFFFFF, 2, 1, OK);

      // And it must still be a working slave, not merely readable.
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000001, 2, OK);
      // ahb_write returns as the data phase closes, so the MSIP flop has not
      // necessarily captured yet -- sample after an edge, not in the same delta.
      repeat(2) @(posedge free_clk);
      if (tb_ahb_aclint.dut.irq_m_software_o[0] !== 1'b1) begin
         $display("ERROR: block did not initialize with an ICG gating purely on hclk_en_o %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  block initializes even when the SoC ICG omits the reset term %t ns", $time);
      end
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000000, 2, OK);

      icg_ignore_reset = 1'b0;

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
