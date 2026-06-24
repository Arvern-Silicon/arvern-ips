//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    multihart_routing
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : multihart_routing
// Module Description : Multi-hart context-to-output routing test. Verifies
//                      that enabling a source for hart 0's M-context drives
//                      irq_m_external_o[0] only; enabling the same source for hart
//                      1's M-context drives irq_m_external_o[1] as well; that the
//                      shared platform-wide pending/in_service state means
//                      claim by one hart drops the other hart's view; and
//                      (SU=1) that the S-context drives irq_s_external_o[hart].
//                      Skipped at NUM_HARTS < 2.
//----------------------------------------------------------------------------

// Base of the PLIC slave window (matches hsel decode in the TB).
`define PLIC_BASE     32'h00400000
`define PRIO_BASE     32'h00000000
`define ENABLE_BASE   32'h00002000
`define ENABLE_STRIDE 32'h00000080
`define TARGET_BASE   32'h00200000
`define TARGET_STRIDE 32'h00001000

// Context indices follow the spec mapping: SU=1 => ctx = 2*hart + s_mode,
// SU=0 => ctx = hart. These are TB localparams so the index is correct in
// every parameter combo.
integer h0_m_ctx;
integer h1_m_ctx;
integer h1_s_ctx;
integer max_prio;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      // Parameter-axis guard: needs at least two harts to compare routing.
      if (NUM_HARTS < 2) begin
         tb_skip_finish("|         (multihart_routing needs NUM_HARTS>=2)         |");
      end

      h0_m_ctx = 0;
      h1_m_ctx = SU_MODE_EN ? 2 : 1;
      h1_s_ctx = 3;                              // only meaningful if SU=1
      max_prio = (32'h1 << PRIO_BITS) - 1;

      $display(" ===============================================");
      $display("|    SETUP: PRIO[1]=MAX, EN ON HART0/M ONLY     |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*1, max_prio, 2, OK);

      // Enable source 1 for hart 0 M-context.
      ahb_write(1, MACHINE,
                `PLIC_BASE + `ENABLE_BASE + h0_m_ctx*`ENABLE_STRIDE + 32'h0,
                32'h0000_0002, 2, OK);

      // Make sure thresholds for the contexts we touch are 0.
      ahb_write(1, MACHINE,
                `PLIC_BASE + `TARGET_BASE + h0_m_ctx*`TARGET_STRIDE + 32'h0,
                32'd0, 2, OK);
      ahb_write(1, MACHINE,
                `PLIC_BASE + `TARGET_BASE + h1_m_ctx*`TARGET_STRIDE + 32'h0,
                32'd0, 2, OK);
      if (SU_MODE_EN) begin
         ahb_write(1, MACHINE,
                   `PLIC_BASE + `TARGET_BASE + h1_s_ctx*`TARGET_STRIDE + 32'h0,
                   32'd0, 2, OK);
      end

      $display(" ===============================================");
      $display("|    SRC1 -> MEXT[0]=1, MEXT[1]=0, SEXT=0       |");
      $display(" ===============================================");

      irq_src[1] = 1'b1;
      @(posedge free_clk);
      @(posedge free_clk);

      if (tb_ahb_plic.dut.irq_m_external_o[0] !== 1'b1) begin
         $display("ERROR: irq_m_external_o[0] expected 1, got %b %t",
                  tb_ahb_plic.dut.irq_m_external_o[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[0]=1 (hart 0 M enabled)");
      end
      if (tb_ahb_plic.dut.irq_m_external_o[1] !== 1'b0) begin
         $display("ERROR: irq_m_external_o[1] expected 0, got %b %t",
                  tb_ahb_plic.dut.irq_m_external_o[1], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[1]=0 (hart 1 M not enabled yet)");
      end
      if (SU_MODE_EN) begin
         if (tb_ahb_plic.dut.irq_s_external_o !== {NUM_HARTS{1'b0}}) begin
            $display("ERROR: irq_s_external_o expected all-0, got %b %t",
                     tb_ahb_plic.dut.irq_s_external_o, $time);
            error = error + 1;
         end else begin
            $display("PASS:  irq_s_external_o all-0 (no S-context enabled)");
         end
      end

      $display(" ===============================================");
      $display("|    ALSO ENABLE SRC1 FOR HART1/M -> MEXT[1]=1  |");
      $display(" ===============================================");

      ahb_write(1, MACHINE,
                `PLIC_BASE + `ENABLE_BASE + h1_m_ctx*`ENABLE_STRIDE + 32'h0,
                32'h0000_0002, 2, OK);
      @(posedge free_clk);

      if (tb_ahb_plic.dut.irq_m_external_o[0] !== 1'b1) begin
         $display("ERROR: irq_m_external_o[0] expected 1 (still asserted), got %b %t",
                  tb_ahb_plic.dut.irq_m_external_o[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[0]=1 (hart 0 M still sees pending)");
      end
      if (tb_ahb_plic.dut.irq_m_external_o[1] !== 1'b1) begin
         $display("ERROR: irq_m_external_o[1] expected 1 after enable, got %b %t",
                  tb_ahb_plic.dut.irq_m_external_o[1], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[1]=1 (hart 1 M now sees pending)");
      end

      $display(" ===============================================");
      $display("|    HART0/M CLAIMS -> BOTH MEXT DROP           |");
      $display(" ===============================================");

      // Read claim_complete[hart0/M]: expect source 1. The same edge that
      // returns the ID clears pending[1] platform-wide, so hart 1 also
      // stops seeing the IRQ.
      ahb_read(1, MACHINE,
               `PLIC_BASE + `TARGET_BASE + h0_m_ctx*`TARGET_STRIDE + 32'h4,
               32'd1, 2, 1, OK);
      @(posedge free_clk);

      if (tb_ahb_plic.dut.irq_m_external_o[0] !== 1'b0) begin
         $display("ERROR: irq_m_external_o[0] expected 0 after claim, got %b %t",
                  tb_ahb_plic.dut.irq_m_external_o[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[0]=0 after hart 0 claim");
      end
      if (tb_ahb_plic.dut.irq_m_external_o[1] !== 1'b0) begin
         $display("ERROR: irq_m_external_o[1] expected 0 after shared-pending claim, got %b %t",
                  tb_ahb_plic.dut.irq_m_external_o[1], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[1]=0 (shared pending cleared by hart 0 claim)");
      end

      $display(" ===============================================");
      $display("|    HART0/M COMPLETES -> LEVEL HIGH -> BOTH RE-ARM |");
      $display(" ===============================================");

      ahb_write(1, MACHINE,
                `PLIC_BASE + `TARGET_BASE + h0_m_ctx*`TARGET_STRIDE + 32'h4,
                32'd1, 2, OK);
      // Wait for in_service[1] to clear and the gateway to re-set pending[1].
      @(posedge free_clk);
      @(posedge free_clk);
      @(posedge free_clk);

      if (tb_ahb_plic.dut.irq_m_external_o[0] !== 1'b1) begin
         $display("ERROR: irq_m_external_o[0] expected 1 after complete, got %b %t",
                  tb_ahb_plic.dut.irq_m_external_o[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[0]=1 after complete (level still high)");
      end
      if (tb_ahb_plic.dut.irq_m_external_o[1] !== 1'b1) begin
         $display("ERROR: irq_m_external_o[1] expected 1 after complete, got %b %t",
                  tb_ahb_plic.dut.irq_m_external_o[1], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[1]=1 after complete (shared re-arm)");
      end

      if (SU_MODE_EN) begin
         $display(" ===============================================");
         $display("|    ENABLE SRC1 FOR HART1/S -> SEXT[1]=1       |");
         $display(" ===============================================");

         ahb_write(1, MACHINE,
                   `PLIC_BASE + `ENABLE_BASE + h1_s_ctx*`ENABLE_STRIDE + 32'h0,
                   32'h0000_0002, 2, OK);
         @(posedge free_clk);

         if (tb_ahb_plic.dut.irq_s_external_o[1] !== 1'b1) begin
            $display("ERROR: irq_s_external_o[1] expected 1 after enable, got %b %t",
                     tb_ahb_plic.dut.irq_s_external_o[1], $time);
            error = error + 1;
         end else begin
            $display("PASS:  irq_s_external_o[1]=1 (hart 1 S sees enabled+pending)");
         end
         if (tb_ahb_plic.dut.irq_s_external_o[0] !== 1'b0) begin
            $display("ERROR: irq_s_external_o[0] expected 0 (hart 0 S not enabled), got %b %t",
                     tb_ahb_plic.dut.irq_s_external_o[0], $time);
            error = error + 1;
         end else begin
            $display("PASS:  irq_s_external_o[0]=0 (hart 0 S not enabled)");
         end
      end

      // Drain: drop level, claim+complete via hart 0 to clear in_service.
      irq_src[1] = 1'b0;
      ahb_read(1, MACHINE,
               `PLIC_BASE + `TARGET_BASE + h0_m_ctx*`TARGET_STRIDE + 32'h4,
               32'd1, 2, 1, OK);
      ahb_write(1, MACHINE,
                `PLIC_BASE + `TARGET_BASE + h0_m_ctx*`TARGET_STRIDE + 32'h4,
                32'd1, 2, OK);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
