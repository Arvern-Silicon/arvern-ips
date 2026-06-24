//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    threshold_claim
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : threshold_claim.v
// Module Description : Threshold + claim/complete handshake test for ctx 0
//                      (hart 0 M-mode). Exercises:
//                        - arbiter priority ordering;
//                        - threshold strictly masking sources at or below;
//                        - claim clearing the pending bit on the same edge;
//                        - complete + still-asserted level => re-trigger;
//                        - complete + released level       => no re-trigger.
//----------------------------------------------------------------------------

// Base of the PLIC slave window (matches hsel decode in the TB).
`define PLIC_BASE     32'h00400000
`define PRIO_BASE     32'h00000000
`define PENDING_BASE  32'h00001000
`define ENABLE_BASE   32'h00002000
`define TARGET_BASE   32'h00200000
`define TARGET_STRIDE 32'h00001000

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      $display(" ===============================================");
      $display("|    SETUP: PRIOS, ENABLES, THRESHOLD=0 (CTX0)  |");
      $display(" ===============================================");

      // priority[1]=3, priority[2]=5, priority[3]=7
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*1, 32'd3, 2, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*2, 32'd5, 2, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*3, 32'd7, 2, OK);

      // Enable sources 1,2,3 for ctx 0.
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0,
                32'h0000_000E, 2, OK);

      // Threshold ctx 0 = 0 (no mask).
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h0,
                32'd0, 2, OK);

      $display(" ===============================================");
      $display("|    ASSERT IRQ SOURCES 1, 2, 3                 |");
      $display(" ===============================================");

      irq_src[1] = 1'b1;
      irq_src[2] = 1'b1;
      irq_src[3] = 1'b1;
      @(posedge free_clk);                     // gateway latches
      @(posedge free_clk);                     // settle

      // irq_m_external_o[0] must be high (sources qualify > threshold=0).
      if (irq_m_external[0] !== 1'b1) begin
         $display("ERROR: irq_m_external_o[0] expected high before claim, got %b %t", irq_m_external[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[0]=1 before claim");
      end

      // Pending word should now show bits 1, 2, 3.
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 32'h0,
               32'h0000_000E, 2, 1, OK);

      $display(" ===============================================");
      $display("|    CLAIM -> EXPECT SOURCE 3 (HIGHEST PRIO)    |");
      $display(" ===============================================");

      // Read claim_complete[ctx 0]; expect source 3.
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
               32'd3, 2, 1, OK);

      // After claim: pending[3] cleared, pending[1], pending[2] remain.
      @(posedge free_clk);
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 32'h0,
               32'h0000_0006, 2, 1, OK);

      $display(" ===============================================");
      $display("|    COMPLETE 3 (LEVEL STILL HIGH -> RE-TRIGGER)|");
      $display(" ===============================================");

      // Complete source 3 while irq_src[3] is still high.
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
                32'd3, 2, OK);
      // Two hclk for in_service[3]<-0 then gateway re-sets pending[3].
      @(posedge free_clk);
      @(posedge free_clk);
      @(posedge free_clk);
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 32'h0,
               32'h0000_000E, 2, 1, OK);

      $display(" ===============================================");
      $display("|    THRESHOLD=6 -> ONLY PRIO>6 (SRC 3) PASSES  |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h0,
                32'd6, 2, OK);
      // Allow one cycle for the threshold flop to update before the claim.
      @(posedge free_clk);

      // Claim -> still source 3 (prio 7 > threshold 6).
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
               32'd3, 2, 1, OK);

      // Drop the level on source 3 BEFORE complete to avoid re-trigger.
      irq_src[3] = 1'b0;
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
                32'd3, 2, OK);
      @(posedge free_clk);
      @(posedge free_clk);
      @(posedge free_clk);

      // pending[3] must now be clear (level dropped + completed).
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 32'h0,
               32'h0000_0006, 2, 1, OK);

      $display(" ===============================================");
      $display("|    THRESHOLD=4 -> SRC 2 (PRIO 5) WINS         |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h0,
                32'd4, 2, OK);
      @(posedge free_clk);

      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
               32'd2, 2, 1, OK);

      // Drop level on src 2, then complete. After both, pending[2] must clear.
      irq_src[2] = 1'b0;
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
                32'd2, 2, OK);
      @(posedge free_clk);
      @(posedge free_clk);
      @(posedge free_clk);

      // Only source 1 remains pending (its prio 3 <= threshold 4 so claim is masked).
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 32'h0,
               32'h0000_0002, 2, 1, OK);

      // And irq_m_external_o[0] should be deasserted (src 1 fails the threshold check).
      if (irq_m_external[0] !== 1'b0) begin
         $display("ERROR: irq_m_external_o[0] expected low when only src 1 pending and thr=4, got %b %t", irq_m_external[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_m_external_o[0]=0 with only src 1 pending and threshold=4");
      end

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      irq_src[1] = 1'b0;
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
