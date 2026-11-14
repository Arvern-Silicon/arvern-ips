//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    irq_enable_gating
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : irq_enable_gating.v
// Module Description : Pending bits are recorded with IRQ_EN=0; enabling a
//                      pending bit raises irq_o on the edge ending the
//                      IRQ_EN write; irq_o / irq_any_o gating per pin;
//                      disabling drops the line and keeps the pending bit;
//                      a W1C drops irq_o and irq_any_o on its edge.
//
// Doc "Interrupts": "Pending bits are recorded whether or not IRQ_EN[n] is
// set; IRQ_EN only gates them onto irq_o[n] and irq_any_o. Enabling an
// interrupt whose bit is already pending raises the line at once." Handler
// sequence: "The write takes effect at the end of its ACCESS cycle, and irq_o
// drops on the same clock edge." Doc "Ports": irq_o = IRQ_PEND & IRQ_EN,
// irq_any_o = OR of irq_o.
//----------------------------------------------------------------------------

integer    p;
integer    q;
reg [31:0] pq;

// Write with exact irq_o / irq_any_o timing across the ACCESS cycle
task wr_irq_exact;
   input [31:0] addr;
   input [31:0] data;
   input [31:0] irq_after;
   reg   [31:0] v_before;
   reg          any_before;
   begin
      v_before     = irq32;
      any_before = irq_any;
      apb_write(0, MACHINE, addr, data, SZ_W, OK);
      @(negedge free_clk);
      chk32(irq32, v_before, "irq_o unchanged during the ACCESS cycle");
      chk(irq_any === any_before, "irq_any_o unchanged during the ACCESS cycle");
      @(posedge free_clk);
      #1;
      chk32(irq32, irq_after, "irq_o on the edge ending the ACCESS cycle");
      chk(irq_any === (irq_after != 0), "irq_any_o on the edge ending the ACCESS cycle");
   end
endtask

initial
   begin
      wait_reset_done(5);
      gpio_ext = 32'h0;
      p  = pick_pin(3);
      q  = pick_pin(6);
      pq = pbit(p) | pbit(q);

      $display(" ===============================================");
      $display("|   PENDING RECORDED WITH IRQ_EN=0              |");
      $display(" ===============================================");
      inputs_on(32'hFFFFFFFF);
      wr(R_IRQ_RISE, pq);
      pins_set(pq);
      cycles(L_IN + 3);
      rd(R_IRQ_PEND, pq);
      chk32(irq32, 32'h0, "irq_o low with IRQ_EN=0");
      chk(irq_any === 1'b0, "irq_any_o low with IRQ_EN=0");

      $display(" ===============================================");
      $display("|   ENABLE RAISES THE LINE AT ONCE              |");
      $display(" ===============================================");
      wr_irq_exact(R_IRQ_EN, pbit(p), pbit(p));
      wr_irq_exact(R_IRQ_EN, pq, pq);
      wr_irq_exact(R_IRQ_EN, pbit(q), pbit(q));        // disable p: line drops, pending kept
      rd(R_IRQ_PEND, pq);
      wr_irq_exact(R_IRQ_EN, 32'h0, 32'h0);
      rd(R_IRQ_PEND, pq);
      wr_irq_exact(R_IRQ_EN, 32'hFFFFFFFF, pq);        // enabling non-pending pins raises nothing

      $display(" ===============================================");
      $display("|   W1C DROPS irq_o / irq_any_o ON ITS EDGE     |");
      $display(" ===============================================");
      if (q != p)
        begin
           wr_irq_exact(R_IRQ_PEND, pbit(p), pbit(q));   // irq_any_o stays (q)
           wr_irq_exact(R_IRQ_PEND, pbit(q), 32'h0);     // irq_any_o drops
        end
      else
        wr_irq_exact(R_IRQ_PEND, pbit(p), 32'h0);
      rd(R_IRQ_PEND, 32'h0);

      $display(" ===============================================");
      $display("|   LEVEL PENDING GATED BY IRQ_EN               |");
      $display(" ===============================================");
      wr(R_IRQ_EN,   32'h0);
      wr(R_IRQ_HIGH, pbit(p));                 // pin p high: level
      rd(R_IRQ_PEND, pbit(p));
      chk32(irq32, 32'h0, "level pending, irq_o low with IRQ_EN=0");
      wr_irq_exact(R_IRQ_EN, pbit(p), pbit(p));
      wr_irq_exact(R_IRQ_EN, 32'h0, 32'h0);
      wr(R_IRQ_HIGH, 32'h0);

      $display(" ===============================================");
      $display("|   EVERY PIN: irq_any_o FOLLOWS EACH irq_o     |");
      $display(" ===============================================");
      wr(R_IRQ_LOW, GPIO_MASK);                // every pin except p and q low: those pend
      cycles(1);
      wr(R_IRQ_RISE, 32'h0);
      rd(R_IRQ_PEND, GPIO_MASK & ~pq);
      for (p = 0; p < GPIO_NR; p = p + 1)
        if ((pq & pbit(p)) == 0)
          begin
             wr_irq_exact(R_IRQ_EN, pbit(p), pbit(p));
             wr_irq_exact(R_IRQ_EN, 32'h0,   32'h0);
          end
      wr(R_IRQ_LOW, 32'h0);

      cycles(20);
      stimulus_done = 1;
   end
