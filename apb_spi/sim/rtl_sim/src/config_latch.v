//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    config_latch
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : config_latch.v
// Module Description : Configuration latched per transaction: CLKDIV, CTRL
//                      (CPOL, CPHA, LSB_FIRST, BSWAP) and CSCFG written while
//                      a select is held keep the old values until the
//                      release (the next entry of the transaction runs with
//                      them, SCK and the held select do not move), the
//                      stored idle levels are applied on the release edge,
//                      and the next transaction runs with the new values; a
//                      CPOL write with no select asserted moves SCK at once,
//                      also with entries waiting (IDLE = 0). A CPOL / CPHA or
//                      CSPOL write swept across the inactive time lands on a
//                      transaction-start edge and applies from the next
//                      transaction only (the monitor latches without it).
//
// Doc "Divider changes".
//----------------------------------------------------------------------------

integer cl_hit_ctrl  = 0;                    // CTRL writes on a start edge
integer cl_hit_cscfg = 0;                    // CSCFG writes on a start edge
integer cl_d;

always @(posedge pclk)
  if (tb_start && snoop_wr)
    begin
       if (snoop_a == 'h01) cl_hit_ctrl  = cl_hit_ctrl + 1;
       if (snoop_a == 'h05) cl_hit_cscfg = cl_hit_cscfg + 1;
    end

initial
   begin
      wait_reset_done(5);
      cs_set(8'h00, 1, 1, 1);
      clk_set(1, 0);
      ctrl_wr(C_EN | C_IDLE_HIGH);
      ent_tx(8, 32'hA5, 1'b1);
      wait_quiet(10000);
      // written while the select is held
      clk_set(3, 0);
      ctrl_wr(C_EN | C_IDLE_HIGH | C_CPOL | C_CPHA | C_LSB | C_BSWAP);
      cs_set(8'hFF, 3, 2, 2);
      repeat (20) @(posedge free_clk);
      chk(spi_sck === 1'b0, "SCK keeps the old idle level while the select is held");
      chk(spi_cs[0] === 1'b0, "the held select keeps its level");
      ent_tx(16, 32'h1234, 1'b0);            // old mode, old divider
      wait_idle(10000);
      chk(t_H == 1, "the transaction kept its divider");
      chk(spi_sck === 1'b1, "the stored CPOL applied at the release");
      chk(spi_cs[0] === 1'b0, "the stored CSPOL applied at the release (active high, inactive low)");
      // the next transaction runs with the new values
      ent_tx(16, 32'h1234, 1'b0);
      wait_idle(10000);
      chk(t_H == 3 && t_cpha && t_lsb && t_bswap, "the next transaction uses the new values");
      // CPOL with no select but entries waiting
      cs_set(8'h00, 1, 1, 1);
      ctrl_wr(C_IDLE_HIGH | C_CPOL);           // EN clear
      ent_tx(8, 32'h3C, 1'b0);
      ctrl_wr(C_IDLE_HIGH);
      @(negedge free_clk);
      chk(spi_sck === 1'b0, "CPOL write moves SCK with entries waiting and no select");
      ctrl_wr(C_EN | C_IDLE_HIGH);
      wait_idle(10000);
      // writes swept across the inactive time onto the start edge
      clk_set(1, 0);
      for (cl_d = 0; cl_d < 16; cl_d = cl_d + 1)
        begin
           cs_set(8'h00, 1, 1, 6);
           ctrl_wr(C_EN | C_IDLE_HIGH);
           ent_tx(8, 32'hA5, 1'b0);
           ent_tx(8, 32'h5A, 1'b0);
           while (tb_release !== 1'b1) @(negedge free_clk);
           repeat (cl_d) @(posedge free_clk);
           ctrl_wr(C_EN | C_IDLE_HIGH | C_CPOL | C_CPHA);
           wait_idle(10000);
        end
      chk(cl_hit_ctrl > 0, "a CTRL write landed on a transaction-start edge");
      for (cl_d = 0; cl_d < 16; cl_d = cl_d + 1)
        begin
           ctrl_wr(C_EN | C_IDLE_HIGH);
           cs_set(8'h00, 1, 1, 6);
           ent_tx(8, 32'hA5, 1'b0);
           ent_tx(8, 32'h5A, 1'b0);
           while (tb_release !== 1'b1) @(negedge free_clk);
           repeat (cl_d) @(posedge free_clk);
           cs_set(8'hFF, 1, 1, 6);
           wait_idle(10000);
        end
      chk(cl_hit_cscfg > 0, "a CSCFG write landed on a transaction-start edge");
      stimulus_done = 1;
   end
