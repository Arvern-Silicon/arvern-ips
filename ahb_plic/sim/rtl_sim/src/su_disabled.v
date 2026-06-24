//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    su_disabled
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : su_disabled
// Module Description : SU_MODE_EN=0 sanity test. With SU disabled the
//                      target loop only instantiates NUM_HARTS M-contexts;
//                      every "would-be" S-context address (anything beyond
//                      ctx index NUM_HARTS-1) must RAZ/WI and irq_s_external_o
//                      must be tied 0. Also exercises one M-context end-to-
//                      end to make sure the SU=0 build still routes IRQs.
//                      Skipped when SU_MODE_EN=1.
//----------------------------------------------------------------------------

// Base of the PLIC slave window (matches hsel decode in the TB).
`define PLIC_BASE     32'h00400000
`define PRIO_BASE     32'h00000000
`define ENABLE_BASE   32'h00002000
`define ENABLE_STRIDE 32'h00000080
`define TARGET_BASE   32'h00200000
`define TARGET_STRIDE 32'h00001000

// Address of the first guaranteed-OOR context in this build: the slot
// immediately past the highest implemented ctx (== NUM_HARTS when SU=0).
integer oor_ctx;
integer max_prio;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      // Parameter-axis guard: this test is meaningful only when SU=0.
      if (SU_MODE_EN != 0) begin
         tb_skip_finish("|              (su_disabled needs SU_MODE_EN=0)          |");
      end

      // First non-existent context index. With SU=0, NUM_CONTEXTS=NUM_HARTS,
      // so any ctx index >= NUM_HARTS is guaranteed to be out of range and
      // not collide with an implemented M-context.
      oor_ctx  = NUM_HARTS;
      max_prio = (32'h1 << PRIO_BITS) - 1;

      $display(" ===============================================");
      $display("|    OOR ENABLE BLOCK IS RAZ/WI                 |");
      $display(" ===============================================");

      // Pick the first slot that cannot exist: ctx == NUM_HARTS. Writing
      // it must be silently dropped and reads must return 0.
      ahb_write(1, MACHINE,
                `PLIC_BASE + `ENABLE_BASE + oor_ctx*`ENABLE_STRIDE + 32'h0,
                32'hFFFF_FFFF, 2, OK);
      ahb_read (1, MACHINE,
                `PLIC_BASE + `ENABLE_BASE + oor_ctx*`ENABLE_STRIDE + 32'h0,
                32'h0000_0000, 2, 1, OK);

      $display(" ===============================================");
      $display("|    OOR TARGET BLOCK (THRESHOLD+CLAIM) RAZ/WI  |");
      $display(" ===============================================");

      // Threshold at oor_ctx and claim/complete at +4 must both RAZ/WI.
      ahb_write(1, MACHINE,
                `PLIC_BASE + `TARGET_BASE + oor_ctx*`TARGET_STRIDE + 32'h0,
                32'hFFFF_FFFF, 2, OK);
      ahb_read (1, MACHINE,
                `PLIC_BASE + `TARGET_BASE + oor_ctx*`TARGET_STRIDE + 32'h0,
                32'h0000_0000, 2, 1, OK);
      ahb_read (1, MACHINE,
                `PLIC_BASE + `TARGET_BASE + oor_ctx*`TARGET_STRIDE + 32'h4,
                32'h0000_0000, 2, 1, OK);

      $display(" ===============================================");
      $display("|    irq_s_external_o TIED 0 WITH SU=0                |");
      $display(" ===============================================");

      if (tb_ahb_plic.dut.irq_s_external_o !== {NUM_HARTS{1'b0}}) begin
         $display("ERROR: irq_s_external_o expected all-0 with SU=0, got %b %t",
                  tb_ahb_plic.dut.irq_s_external_o, $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_external_o all-0 (tied off when SU=0)");
      end

      $display(" ===============================================");
      $display("|    SANITY: M-CONTEXT (CTX 0) STILL ROUTES IRQ |");
      $display(" ===============================================");

      // Set priority[1]=max, enable source 1 on ctx 0, threshold 0.
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*1, max_prio, 2, OK);
      ahb_write(1, MACHINE,
                `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE + 32'h0,
                32'h0000_0002, 2, OK);
      ahb_write(1, MACHINE,
                `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h0,
                32'd0, 2, OK);

      irq_src[1] = 1'b1;
      @(posedge free_clk);
      @(posedge free_clk);

      if (tb_ahb_plic.dut.irq_m_external_o[0] !== 1'b1) begin
         $display("ERROR: irq_m_external_o[0] expected 1 (M ctx 0 enabled), got %b %t",
                  tb_ahb_plic.dut.irq_m_external_o[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[0]=1 (M-context still routes under SU=0)");
      end
      if (tb_ahb_plic.dut.irq_s_external_o !== {NUM_HARTS{1'b0}}) begin
         $display("ERROR: irq_s_external_o expected all-0 (no S contexts), got %b %t",
                  tb_ahb_plic.dut.irq_s_external_o, $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_external_o still all-0 after IRQ asserted");
      end

      // Claim and complete to leave the IP in a clean state.
      ahb_read(1, MACHINE,
               `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
               32'd1, 2, 1, OK);
      irq_src[1] = 1'b0;
      ahb_write(1, MACHINE,
                `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
                32'd1, 2, OK);
      @(posedge free_clk);
      @(posedge free_clk);
      @(posedge free_clk);

      if (tb_ahb_plic.dut.irq_m_external_o[0] !== 1'b0) begin
         $display("ERROR: irq_m_external_o[0] expected 0 after drain, got %b %t",
                  tb_ahb_plic.dut.irq_m_external_o[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[0]=0 after drain");
      end

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
