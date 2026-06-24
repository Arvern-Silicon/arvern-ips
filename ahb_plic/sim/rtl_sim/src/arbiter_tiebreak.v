//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arbiter_tiebreak
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arbiter_tiebreak.v
// Module Description : Arbiter priority-tie behaviour. Three sources at the
//                      same priority must be served lowest-source-ID first.
//                      The test drops each source level BEFORE issuing
//                      complete so the gateway does not re-trigger the
//                      claimed source on the next cycle (otherwise the next
//                      claim would return the same lowest-ID winner again,
//                      not the next-up source).
//----------------------------------------------------------------------------

// Base of the PLIC slave window (matches hsel decode in the TB).
`define PLIC_BASE     32'h00400000
`define PRIO_BASE     32'h00000000
`define ENABLE_BASE   32'h00002000
`define TARGET_BASE   32'h00200000
`define TARGET_STRIDE 32'h00001000

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      $display(" ===============================================");
      $display("|    SETUP: PRIO[5]=PRIO[10]=PRIO[15]=7         |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*5 , 32'd7, 2, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*10, 32'd7, 2, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*15, 32'd7, 2, OK);

      // Enable sources 5, 10, 15 for ctx 0.
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0,
                (32'h1 << 5) | (32'h1 << 10) | (32'h1 << 15), 2, OK);

      // Threshold ctx 0 = 0.
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h0,
                32'd0, 2, OK);

      $display(" ===============================================");
      $display("|    ASSERT 5, 10, 15 -> CLAIM EXPECTS 5        |");
      $display(" ===============================================");

      irq_src[5]  = 1'b1;
      irq_src[10] = 1'b1;
      irq_src[15] = 1'b1;
      @(posedge free_clk);
      @(posedge free_clk);

      // Drop src 5 BEFORE claim+complete so gateway does not re-trigger.
      // (claim itself only clears pending; the level-still-high gateway
      // would re-arm pending two cycles after complete and we would see
      // 5 again on the next claim.)
      irq_src[5] = 1'b0;
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
               32'd5, 2, 1, OK);

      // Complete source 5.
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
                32'd5, 2, OK);
      @(posedge free_clk);
      @(posedge free_clk);

      $display(" ===============================================");
      $display("|    NEXT CLAIM EXPECTS 10                      |");
      $display(" ===============================================");

      irq_src[10] = 1'b0;                        // drop level before claim+complete
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
               32'd10, 2, 1, OK);

      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
                32'd10, 2, OK);
      @(posedge free_clk);
      @(posedge free_clk);

      $display(" ===============================================");
      $display("|    NEXT CLAIM EXPECTS 15                      |");
      $display(" ===============================================");

      irq_src[15] = 1'b0;                        // drop level before claim+complete
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
               32'd15, 2, 1, OK);

      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
                32'd15, 2, OK);
      @(posedge free_clk);
      @(posedge free_clk);

      // No source left pending -> claim returns 0.
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
               32'd0, 2, 1, OK);

      $display(" ===============================================");
      $display("|    RE-ASSERT ALL THREE -> CLAIM EXPECTS 5     |");
      $display(" ===============================================");

      // Drive all three high again. Lowest-ID tie-break should bring 5 back.
      irq_src[5]  = 1'b1;
      irq_src[10] = 1'b1;
      irq_src[15] = 1'b1;
      @(posedge free_clk);
      @(posedge free_clk);

      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
               32'd5, 2, 1, OK);

      // Drop all sources, complete the in-service entry, settle.
      irq_src[5]  = 1'b0;
      irq_src[10] = 1'b0;
      irq_src[15] = 1'b0;
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE + 32'h4,
                32'd5, 2, OK);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
