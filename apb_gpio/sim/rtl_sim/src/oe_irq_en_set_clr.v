//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    oe_irq_en_set_clr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : oe_irq_en_set_clr.v
// Module Description : The OE_SET / OE_CLR and IRQ_EN_SET / IRQ_EN_CLR write
//                      aliases: writing 1 sets / clears the bit of OE or
//                      IRQ_EN, 0 leaves it; word, half-word and byte writes
//                      change only their lanes; the aliases read 0; gpio_oe_o
//                      and irq_o follow at once. A refused alias write changes
//                      nothing. The reference model checks throughout.
//
// Doc "Register map": OE_SET 0x50, OE_CLR 0x54, IRQ_EN_SET 0x58,
// IRQ_EN_CLR 0x5C, WO.
//----------------------------------------------------------------------------

integer    ii;
reg [31:0] oe;
reg [31:0] en;
reg [31:0] v;
reg [31:0] a;
reg  [1:0] sz;
reg [31:0] lm;

initial
   begin
      wait_reset_done(5);
      // Every pin pending (high level), so irq_o shows IRQ_EN directly
      wr(R_IRQ_HIGH, 32'hFFFFFFFF);
      gpio_ext = 32'hFFFFFFFF;
      inputs_on(32'hFFFFFFFF);
      oe = 32'h0;
      en = 32'h0;
      model_check_en = 1'b1;

      $display(" ===============================================");
      $display("|   WORD SET / CLEAR                            |");
      $display(" ===============================================");
      wr(R_OE_SET,     32'h0F0F0F0F); oe = (oe |  32'h0F0F0F0F) & GPIO_MASK;
      chk32(gpio_oe32, oe, "OE_SET");
      wr(R_OE_SET,     32'h00FF0000); oe = (oe |  32'h00FF0000) & GPIO_MASK;
      wr(R_OE_CLR,     32'h03000003); oe =  oe & ~32'h03000003;
      chk32(gpio_oe32, oe, "OE_CLR");
      rd(R_OE, oe);
      wr(R_IRQ_EN_SET, 32'hA5A5A5A5); en = (en |  32'hA5A5A5A5) & GPIO_MASK;
      chk32(irq32, en, "IRQ_EN_SET");
      wr(R_IRQ_EN_CLR, 32'h000000FF); en =  en & ~32'h000000FF;
      chk32(irq32, en, "IRQ_EN_CLR");
      rd(R_IRQ_EN, en);
      rd(R_OE_SET, 32'h0);
      rd(R_OE_CLR, 32'h0);
      rd(R_IRQ_EN_SET, 32'h0);
      rd(R_IRQ_EN_CLR, 32'h0);

      $display(" ===============================================");
      $display("|   RANDOM LANES                                |");
      $display(" ===============================================");
      for (ii = 0; ii < 200; ii = ii + 1)
        begin
           v  = $urandom;
           sz = $urandom % 3;
           a  = reg_addr(17 + ($urandom % 4));
           a  = a + ((sz == SZ_B) ? ($urandom % 4) : (sz == SZ_H) ? (2*($urandom % 2)) : 0);
           lm = lane_mask(a, sz) & lane_place(a, sz, v) & GPIO_MASK;
           apb_write(1, MACHINE, a, v, sz, OK);
           case ((a - GPIO_BASE) & ~32'h3)
             32'h50: oe = oe |  lm;
             32'h54: oe = oe & ~lm;
             32'h58: en = en |  lm;
             default: en = en & ~lm;
           endcase
           chk32(gpio_oe32, oe, "gpio_oe_o after an alias write");
           chk32(irq32,     en, "irq_o after an alias write");
        end
      rd(R_OE, oe);
      rd(R_IRQ_EN, en);

      $display(" ===============================================");
      $display("|   REFUSED ALIAS WRITES                        |");
      $display(" ===============================================");
      wr(R_MDELEG, 32'h0000010F);
      apb_write(1, USER,       R_OE_SET,     32'hFFFFFFFF, SZ_W, ERROR);
      apb_write(1, SUPERVISOR, R_OE_CLR,     32'hFFFFFFFF, SZ_W, ERROR);
      apb_write(1, USER_S,     R_IRQ_EN_SET, 32'hFFFFFFFF, SZ_W, ERROR);
      apb_write(1, SUPERVISOR, R_IRQ_EN_CLR, 32'hFFFFFFFF, SZ_W, ERROR);
      chk32(gpio_oe32, oe, "gpio_oe_o unchanged by refused alias writes");
      chk32(irq32,     en, "irq_o unchanged by refused alias writes");
      wr(R_MDELEG, MDELEG_RST_WORD);

      cycles(5);
      model_check_en = 1'b0;
      cycles(20);
      stimulus_done = 1;
   end
