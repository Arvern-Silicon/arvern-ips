//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    random_irq
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : random_irq
// Module Description : Constrained-random PLIC stimulus. The suite was
//                      directed-only (the `SEED was seeded into $urandom but no
//                      stimulus consumed it), so re-runs explored nothing new.
//                      This randomizes priorities, enables, threshold, and the
//                      per-source irq_src vector, interleaving random
//                      claim/complete handshakes. Correctness is enforced
//                      CONTINUOUSLY by the always-on reference-model scoreboard
//                      (SB-EIP / SB-TOP), so every random state is checked
//                      without hand-coding expected values. A fresh seed each
//                      run_sweep invocation now explores new orderings.
//----------------------------------------------------------------------------

`define PLIC_BASE     32'h00400000
`define PRIO_BASE     32'h00000000
`define ENABLE_BASE   32'h00002000
`define TARGET_BASE   32'h00200000

localparam RND_SRCS = (NUM_SOURCES < 8) ? NUM_SOURCES : 8;

integer i;
integer it;
reg [31:0] rnd;
reg [31:0] claim_id;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|     PLIC : CONSTRAINED-RANDOM (scoreboard)    |");
      $display(" ===============================================");

      // Random priorities (1..max) and enable the low source window for ctx 0.
      for (i = 1; i <= RND_SRCS; i = i + 1) begin
         rnd = ($urandom % ((1 << PRIO_BITS) - 1)) + 1;   // 1 .. 2^PB-1
         ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*i, rnd, 2, OK);
      end
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0,
                (32'h1 << (RND_SRCS+1)) - 2, 2, OK);       // enable bits 1..RND_SRCS

      // Random threshold 0..3.
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0, $urandom % 4, 2, OK);

      // Random stimulus loop -- the scoreboard checks EIP/TOP every cycle.
      for (it = 0; it < 40; it = it + 1) begin
         // Randomly drive each source's level line.
         for (i = 1; i <= RND_SRCS; i = i + 1)
            irq_src[i] = $urandom & 32'h1;

         repeat (2) @(posedge free_clk);

         // Occasionally claim + complete whatever the arbiter currently offers.
         if (($urandom & 32'h3) == 32'h0) begin
            ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd0, 2, 0, OK);
            claim_id = tb_ahb_plic.dut.tgt_top_id[0];
            if (claim_id != 0) begin
               // Completing requires the source still enabled (it is).
               ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, claim_id, 2, OK);
            end
            repeat (2) @(posedge free_clk);
         end
      end

      // Quiesce.
      for (i = 1; i <= RND_SRCS; i = i + 1)
         irq_src[i] = 1'b0;
      repeat (8) @(posedge free_clk);

      $display("PASS:  random sequence completed; reference-model scoreboard verified every cycle %t ns", $time);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
