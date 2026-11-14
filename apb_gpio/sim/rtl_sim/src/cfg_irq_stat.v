//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    cfg_irq_stat
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : cfg_irq_stat.v
// Module Description : CFG and IRQ_STAT. CFG reads the build constants
//                      (ALT_NR [2:0], SYNC_EN [4], INP_CGATE_EN [5], version
//                      [31:28] = 1) at every size and ignores writes.
//                      IRQ_STAT reads IRQ_PEND & IRQ_EN for latched edges
//                      and live levels, ignores writes (a write of ones
//                      clears nothing), and follows a W1C of IRQ_PEND and an
//                      IRQ_EN change at once. The reference model checks
//                      throughout.
//
// Doc "Register map": CFG 0x2C RO, IRQ_STAT 0x4C RO; doc "Interrupts".
//----------------------------------------------------------------------------

reg [31:0] pend;

initial
   begin
      wait_reset_done(5);
      model_check_en = 1'b1;

      $display(" ===============================================");
      $display("|   CFG                                         |");
      $display(" ===============================================");
      rd(R_CFG, CFG_VALUE);
      apb_read(1, MACHINE, R_CFG + 3, CFG_VALUE, SZ_B, 1'b1, OK);
      apb_read(1, MACHINE, R_CFG + 2, CFG_VALUE, SZ_H, 1'b1, OK);
      wr(R_CFG, 32'h00000000);
      wr(R_CFG, 32'hFFFFFFFF);
      rd(R_CFG, CFG_VALUE);

      $display(" ===============================================");
      $display("|   IRQ_STAT                                    |");
      $display(" ===============================================");
      gpio_ext = 32'h0;
      inputs_on(32'hFFFFFFFF);
      wr(R_IRQ_RISE, 32'hFFFFFFFF);
      pins_set(32'h0000FFFF);
      cycles(L_IN + 3);
      wr(R_IRQ_RISE, 32'h0);
      pend = 32'h0000FFFF & GPIO_MASK;
      rd(R_IRQ_PEND, pend);
      rd(R_IRQ_STAT, 32'h0);                           // IRQ_EN all 0
      wr(R_IRQ_EN, 32'h00FF00FF);
      rd(R_IRQ_STAT, pend & 32'h00FF00FF);
      wr(R_IRQ_STAT, 32'hFFFFFFFF);                    // RO: clears nothing
      rd(R_IRQ_STAT, pend & 32'h00FF00FF);
      rd(R_IRQ_PEND, pend);
      wr(R_IRQ_PEND, 32'h0000000F);
      pend = pend & ~32'h0000000F;
      rd(R_IRQ_STAT, pend & 32'h00FF00FF);
      // A live level shows too
      wr(R_IRQ_HIGH, 32'h00F00000);
      pins_set(32'h00F0FFFF);
      cycles(L_IN + 2);
      rd(R_IRQ_STAT, (pend | (32'h00F00000 & GPIO_MASK)) & 32'h00FF00FF);
      wr(R_IRQ_EN, 32'h0);
      rd(R_IRQ_STAT, 32'h0);

      cycles(5);
      model_check_en = 1'b0;
      cycles(20);
      stimulus_done = 1;
   end
