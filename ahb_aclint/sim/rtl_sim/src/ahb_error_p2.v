//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_error_p2
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_error_p2
// Module Description : Cycle-accurate check of the two-cycle AHB-Lite ERROR
//                      protocol (ahb_aclint.v:295-307). The standard BFM
//                      samples hresp only ONCE, so a regression to a 1-cycle
//                      error (hresp drops in P2) or a wrong hreadyout shape
//                      would pass. A denied access must drive:
//                        P1 : hresp=1, hreadyout=0  (error, stall)
//                        P2 : hresp=1, hreadyout=1  (error, complete)
//                        next: hresp=0              (recovered)
//                      Requires PRIV_CHECK_EN=1 (default config).
//----------------------------------------------------------------------------

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);

      if (PRIV_CHECK_EN != 1) begin
         tb_skip_finish("ahb_error_p2 requires PRIV_CHECK_EN=1 (default config)");
      end

      repeat(10) @(posedge free_clk);

      $display(" ===============================================");
      $display("|        AHB : TWO-CYCLE ERROR (P1 + P2)        |");
      $display(" ===============================================");

      // Drive the address phase of a DENIED access: S-mode read of MSIP[0]
      // (MSWI is an M-only window). hprot[1]=1, hsmode=1 -> SUPERVISOR.
      haddr  = 32'h00400000;
      htrans = 2'b10;          // NONSEQ
      hwrite = 1'b0;
      hprot  = 4'h2;
      hsmode = 1'b1;
      hsize  = 3'b010;

      @(posedge free_clk);
      #1;
      // Address phase accepted -> go idle so no further access starts.
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hprot  = 4'h0;
      hsmode = 1'b0;

      // --- P1: first error cycle (stall) ---
      if ((hresp === 1'b1) && (hreadyout === 1'b0)) begin
         $display("PASS:  P1 -- hresp=1, hreadyout=0 (error + stall) %t ns", $time);
      end else begin
         $display("ERROR: P1 -- expected hresp=1/hreadyout=0, got hresp=%b/hreadyout=%b %t ns",
                  hresp, hreadyout, $time);
         error = error + 1;
      end

      @(posedge free_clk);
      #1;
      // --- P2: second error cycle (complete) ---
      if ((hresp === 1'b1) && (hreadyout === 1'b1)) begin
         $display("PASS:  P2 -- hresp=1, hreadyout=1 (error + complete) %t ns", $time);
      end else begin
         $display("ERROR: P2 -- expected hresp=1/hreadyout=1, got hresp=%b/hreadyout=%b %t ns",
                  hresp, hreadyout, $time);
         error = error + 1;
      end

      @(posedge free_clk);
      #1;
      // --- Recovery: hresp must drop back to 0 ---
      if (hresp === 1'b0) begin
         $display("PASS:  post-error -- hresp returned to 0 %t ns", $time);
      end else begin
         $display("ERROR: post-error -- hresp still %b (error not 2 cycles exactly) %t ns", hresp, $time);
         error = error + 1;
      end

      // Sanity: a legal M-mode access right after must still succeed OK.
      ahb_read(1, MACHINE, 32'h00400000, 32'h00000000, 2, 1, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
