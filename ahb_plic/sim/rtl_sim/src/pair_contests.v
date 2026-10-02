//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    pair_contests
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : pair_contests
// Module Description : Every adjacent source pair (2k, 2k+1), k >= 1, contested alone
//                      on ctx 0: even ID higher, odd ID higher, then equal
//                      priority (the lowest ID wins the tie). The winner is claimed
//                      and completed first, then the loser. With PRIO_BITS=1 the
//                      loser of an unequal contest sits at priority 0, which never
//                      wins a claim: the claim after the winner returns 0 until the
//                      loser is raised to priority 1.
//----------------------------------------------------------------------------

`define PLIC_BASE     32'h00400000
`define PRIO_BASE     32'h00000000
`define PENDING_BASE  32'h00001000
`define ENABLE_BASE   32'h00002000
`define TARGET_BASE   32'h00200000

localparam PC_HI = (PRIO_BITS > 1) ? 2 : 1;
localparam PC_LO = (PRIO_BITS > 1) ? 1 : 0;

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

integer k;
integer a;
integer b;
integer cse;
integer win;
integer lose;
integer pa;
integer pb;
reg [31:0] pair_bits;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE, 32'd0, 2, OK);

      for (k = 1; 2*k + 1 <= NUM_SOURCES; k = k + 1) begin
         a = 2*k;
         b = 2*k + 1;
         pair_bits = (32'h1 << (a%32)) | (32'h1 << (b%32));
         ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 4*(a/32), pair_bits, 2, OK);

         for (cse = 0; cse < 3; cse = cse + 1) begin
            // cse 0: even ID higher, 1: odd ID higher, 2: tie.
            pa   = (cse == 1) ? PC_LO : PC_HI;
            pb   = (cse == 0) ? PC_LO : PC_HI;
            win  = (cse == 1) ? b : a;
            lose = (cse == 1) ? a : b;
            ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*a, pa, 2, OK);
            ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*b, pb, 2, OK);

            irq_src[a] = 1'b1;
            irq_src[b] = 1'b1;
            repeat(2) @(posedge free_clk); #1;
            irq_src[a] = 1'b0;
            irq_src[b] = 1'b0;
            chk(irq_m_external === 1, "pair pending: irq_m_external[0] not high");
            ahb_read(1, MACHINE, `PLIC_BASE + `PENDING_BASE + 4*(a/32), pair_bits, 2, 1, OK);

            ahb_read (1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, win, 2, 1, OK);
            ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, win, 2, OK);
            if ((cse != 2) && (PC_LO == 0)) begin
               // Loser at priority 0: pending but never claimed.
               ahb_read (1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd0, 2, 1, OK);
               ahb_read (1, MACHINE, `PLIC_BASE + `PENDING_BASE + 4*(a/32), 32'h1 << (lose%32), 2, 1, OK);
               ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*lose, 32'd1, 2, OK);
            end
            ahb_read (1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, lose, 2, 1, OK);
            ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, lose, 2, OK);
            ahb_read (1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd0, 2, 1, OK);
            #1;
            chk(irq_m_external === 0, "pair drained: irq_m_external[0] still high");
         end

         ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*a, 32'h0, 2, OK);
         ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*b, 32'h0, 2, OK);
         ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 4*(a/32), 32'h0, 2, OK);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
