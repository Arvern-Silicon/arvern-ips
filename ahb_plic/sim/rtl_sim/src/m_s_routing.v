//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    m_s_routing
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : m_s_routing.v
// Module Description : M-mode / S-mode external IRQ routing test. With
//                      SU_MODE_EN=1, ctx 0 is hart 0 M-mode and ctx 1 is
//                      hart 0 S-mode. The pending and in_service flops are
//                      *shared* across contexts -- when any context claims
//                      a source, the other context stops seeing it pending
//                      until the gateway re-arms on complete.
//----------------------------------------------------------------------------

// Base of the PLIC slave window (matches hsel decode in the TB).
`define PLIC_BASE     32'h00400000
`define PRIO_BASE     32'h00000000
`define ENABLE_BASE   32'h00002000
`define ENABLE_STRIDE 32'h00000080
`define TARGET_BASE   32'h00200000
`define TARGET_STRIDE 32'h00001000

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      $display(" ===============================================");
      $display("|    SETUP: PRIO[1]=5, EN[CTX0]=src1 ONLY       |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*1, 32'd5, 2, OK);

      // Enable source 1 for ctx 0 (M) only.
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h0,
                32'h0000_0002, 2, OK);
      // Ctx 1 (S) starts with no enables.
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h1*`ENABLE_STRIDE + 32'h0,
                32'h0000_0000, 2, OK);

      // Thresholds both at 0.
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h0,
                32'd0, 2, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h1*`TARGET_STRIDE + 32'h0,
                32'd0, 2, OK);

      $display(" ===============================================");
      $display("|    ASSERT src 1 -> MEXT=1, SEXT=0             |");
      $display(" ===============================================");

      irq_src[1] = 1'b1;
      @(posedge free_clk);
      @(posedge free_clk);

      if (irq_m_external[0] !== 1'b1) begin
         $display("ERROR: irq_m_external_o[0] expected 1, got %b %t", irq_m_external[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[0]=1 (M enabled, src 1 pending)");
      end
      if (irq_s_external[0] !== 1'b0) begin
         $display("ERROR: irq_s_external_o[0] expected 0, got %b %t", irq_s_external[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_external_o[0]=0 (S not enabled)");
      end

      $display(" ===============================================");
      $display("|    CTX 0 (M) CLAIMS -> MEXT DROPS             |");
      $display(" ===============================================");

      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
               32'd1, 2, 1, OK);
      @(posedge free_clk);

      // After claim, pending[1]=0 and in_service[1]=1. MEXT must drop.
      if (irq_m_external[0] !== 1'b0) begin
         $display("ERROR: irq_m_external_o[0] expected 0 after M-claim, got %b %t", irq_m_external[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[0]=0 after M-claim cleared pending");
      end

      $display(" ===============================================");
      $display("|    COMPLETE 1 (M) -> LEVEL HIGH -> MEXT RE-ARM|");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
                32'd1, 2, OK);
      // Wait for in_service[1] to clear then gateway re-set pending[1].
      @(posedge free_clk);
      @(posedge free_clk);
      @(posedge free_clk);

      if (irq_m_external[0] !== 1'b1) begin
         $display("ERROR: irq_m_external_o[0] expected 1 after complete (level high), got %b %t", irq_m_external[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[0]=1 after complete + level still high");
      end
      if (irq_s_external[0] !== 1'b0) begin
         $display("ERROR: irq_s_external_o[0] expected 0 (S still not enabled), got %b %t", irq_s_external[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_external_o[0]=0 (S still not enabled)");
      end

      $display(" ===============================================");
      $display("|    ALSO ENABLE src 1 FOR CTX 1 (S) -> SEXT=1  |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h1*`ENABLE_STRIDE + 32'h0,
                32'h0000_0002, 2, OK);
      // Allow the enable flop to propagate before sampling.
      @(posedge free_clk);

      if (irq_s_external[0] !== 1'b1) begin
         $display("ERROR: irq_s_external_o[0] expected 1 after enabling S, got %b %t", irq_s_external[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_external_o[0]=1 after enabling S-context for src 1");
      end

      $display(" ===============================================");
      $display("|    CTX 1 (S) CLAIMS -> BOTH MEXT AND SEXT DROP|");
      $display(" ===============================================");

      // Claim from S-context.
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h1*`TARGET_STRIDE + 32'h4,
               32'd1, 2, 1, OK);
      @(posedge free_clk);

      // Pending[1] is now 0 and in_service[1]=1, shared by both arbiters,
      // so both MEXT and SEXT must be 0.
      if (irq_s_external[0] !== 1'b0) begin
         $display("ERROR: irq_s_external_o[0] expected 0 after S-claim, got %b %t", irq_s_external[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_external_o[0]=0 after S-claim");
      end
      if (irq_m_external[0] !== 1'b0) begin
         $display("ERROR: irq_m_external_o[0] expected 0 after S-claim (shared pending), got %b %t", irq_m_external[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[0]=0 after S-claim (shared pending/in_service)");
      end

      $display(" ===============================================");
      $display("|    COMPLETE 1 (S) -> LEVEL HIGH -> BOTH RE-ARM|");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h1*`TARGET_STRIDE + 32'h4,
                32'd1, 2, OK);
      @(posedge free_clk);
      @(posedge free_clk);
      @(posedge free_clk);

      if (irq_m_external[0] !== 1'b1) begin
         $display("ERROR: irq_m_external_o[0] expected 1 after S-complete, got %b %t", irq_m_external[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[0]=1 after S-complete (both contexts see pending again)");
      end
      if (irq_s_external[0] !== 1'b1) begin
         $display("ERROR: irq_s_external_o[0] expected 1 after S-complete, got %b %t", irq_s_external[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_external_o[0]=1 after S-complete");
      end

      // Drain: drop level, claim+complete via M to clear.
      irq_src[1] = 1'b0;
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
               32'd1, 2, 1, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
                32'd1, 2, OK);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
