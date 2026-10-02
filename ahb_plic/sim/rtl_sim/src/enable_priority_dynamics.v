//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    enable_priority_dynamics
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : enable_priority_dynamics
// Module Description : Enable and priority changed under a live source on ctx 0.
//                      Clearing the enable, or setting the priority to 0, of a
//                      pending source drops the output and makes the claim return
//                      0 while the pending bit stays set; restoring it makes the
//                      source claimable again. A complete written after the enable
//                      was cleared is dropped (Chapter 9, "Complete before
//                      disabling"): the source stays in service and its high line
//                      does not re-pend; re-enabling and completing clears it and
//                      the line re-pends.
//----------------------------------------------------------------------------

`define PLIC_BASE     32'h00400000
`define PRIO_BASE     32'h00000000
`define PENDING_BASE  32'h00001000
`define ENABLE_BASE   32'h00002000
`define TARGET_BASE   32'h00200000

localparam ED_MAXP = (1 << PRIO_BITS) - 1;
localparam ED_SRC  = (NUM_SOURCES >= 5) ? 5 : NUM_SOURCES;
localparam ED_EN   = ED_SRC % 32;                   // bit in its enable / pending word
localparam ED_WORD = 4*(ED_SRC / 32);               // byte offset of that word

task chk;
   input        cond;
   input [8*80-1:0] msg;
   begin
      if (cond !== 1'b1) begin
         $display("ERROR: %0s %t ns", msg, $time);
         error = error + 1;
      end
   end
endtask

task ed_enable;
   input on;
   begin
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + ED_WORD, on ? (32'h1 << ED_EN) : 32'h0, 2, OK);
      @(posedge free_clk); #1;
   end
endtask

task ed_prio;
   input [31:0] p;
   begin
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*ED_SRC, p, 2, OK);
      @(posedge free_clk); #1;
   end
endtask

task ed_pending;
   input set;
   begin
      ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + ED_WORD, set ? (32'h1 << ED_EN) : 32'h0, 2, 1, OK);
   end
endtask

task ed_claim;
   input [31:0] id;
   begin
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, id, 2, 1, OK);
   end
endtask

task ed_complete;
   begin
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, ED_SRC, 2, OK);
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      ed_prio(ED_MAXP);
      ed_enable(1);
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE, 32'd0, 2, OK);
      irq_src[ED_SRC] = 1'b1;
      repeat(2) @(posedge free_clk); #1;
      chk(irq_m_external === 1, "setup: output not high");

      $display(" ===============================================");
      $display("|    ENABLE CLEARED UNDER A PENDING SOURCE      |");
      $display(" ===============================================");

      ed_enable(0);
      chk(irq_m_external === 0, "enable cleared: output still high");
      ed_claim(0);
      ed_pending(1);
      ed_enable(1);
      chk(irq_m_external === 1, "re-enabled: output not high");
      ed_claim(ED_SRC);
      #1;
      chk(irq_m_external === 0, "claimed: output still high");
      ed_complete;                                  // line high: re-pends
      repeat(2) @(posedge free_clk); #1;
      chk(irq_m_external === 1, "complete with the line high: source did not re-pend");

      $display(" ===============================================");
      $display("|    PRIORITY 0 UNDER A PENDING SOURCE          |");
      $display(" ===============================================");

      ed_prio(0);
      chk(irq_m_external === 0, "priority 0: output still high");
      ed_claim(0);
      ed_pending(1);
      ed_prio(1);
      chk(irq_m_external === 1, "priority 1: output not high");
      ed_claim(ED_SRC);

      $display(" ===============================================");
      $display("|    COMPLETE AFTER DISABLE IS DROPPED          |");
      $display(" ===============================================");

      ed_enable(0);
      ed_complete;
      repeat(3) @(posedge free_clk); #1;
      chk(dut.in_service_flat[ED_SRC] === 1'b1, "complete of a disabled source cleared in_service");
      ed_pending(0);
      ed_enable(1);
      chk(irq_m_external === 0, "re-enabled while still in service: output high");
      ed_pending(0);
      ed_complete;
      repeat(2) @(posedge free_clk); #1;
      chk(dut.in_service_flat[ED_SRC] === 1'b0, "complete after re-enable did not clear in_service");
      chk(irq_m_external === 1, "complete after re-enable: high line did not re-pend");
      ed_pending(1);

      irq_src[ED_SRC] = 1'b0;
      ed_claim(ED_SRC);
      ed_complete;
      repeat(2) @(posedge free_clk); #1;
      chk(irq_m_external === 0, "final: output still high");
      ed_pending(0);
      ed_claim(0);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
