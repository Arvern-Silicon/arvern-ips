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
//                      protocol (ahb_aclint.v, section 9.b). The standard BFM
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

      $display("");
      $display(" ===============================================");
      $display("|   AHB : A NEW TRANSFER DURING THE P2 CYCLE    |");
      $display(" ===============================================");

      // HREADYOUT is high again in P2, so AHB-Lite lets the manager present the
      // next address phase there. err_state must retire to IDLE on that same
      // edge: a second denied access then gets its OWN full two-cycle error
      // rather than inheriting a half-finished one, and a legal access is not
      // contaminated by the error still being reported when it was issued.

      // --- denied, then a second denied presented in P2 ---
      haddr  = 32'h00400000;
      htrans = 2'b10;
      hwrite = 1'b0;
      hprot  = 4'h2;
      hsmode = 1'b1;
      hsize  = 3'b010;

      @(posedge free_clk);
      #1;
      haddr  = 32'h00000000;      // idle through P1: the address is not accepted anyway
      htrans = 2'b00;
      hprot  = 4'h0;
      hsmode = 1'b0;

      if (!((hresp === 1'b1) && (hreadyout === 1'b0))) begin
         $display("ERROR: pass 2 P1 -- expected hresp=1/hreadyout=0, got %b/%b %t ns",
                  hresp, hreadyout, $time);
         error = error + 1;
      end

      @(posedge free_clk);
      #1;
      if (!((hresp === 1'b1) && (hreadyout === 1'b1))) begin
         $display("ERROR: pass 2 P2 -- expected hresp=1/hreadyout=1, got %b/%b %t ns",
                  hresp, hreadyout, $time);
         error = error + 1;
      end

      // Present the SECOND denied access in this P2 cycle.
      haddr  = 32'h00404000;      // MTIMECMP_LO[0] -- also an M-only window
      htrans = 2'b10;
      hwrite = 1'b0;
      hprot  = 4'h2;
      hsmode = 1'b1;
      hsize  = 3'b010;

      @(posedge free_clk);
      #1;
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hprot  = 4'h0;
      hsmode = 1'b0;

      if ((hresp === 1'b1) && (hreadyout === 1'b0)) begin
         $display("PASS:  transfer issued in P2 gets its own P1 (stall) %t ns", $time);
      end else begin
         $display("ERROR: transfer issued in P2 -- expected a fresh P1 (hresp=1/hreadyout=0), got %b/%b %t ns",
                  hresp, hreadyout, $time);
         error = error + 1;
      end

      @(posedge free_clk);
      #1;
      if ((hresp === 1'b1) && (hreadyout === 1'b1)) begin
         $display("PASS:  ... and its own P2 (complete) %t ns", $time);
      end else begin
         $display("ERROR: transfer issued in P2 -- expected its own P2, got %b/%b %t ns",
                  hresp, hreadyout, $time);
         error = error + 1;
      end

      @(posedge free_clk);
      #1;
      if (hresp === 1'b0) begin
         $display("PASS:  back-to-back errors recovered -- hresp low %t ns", $time);
      end else begin
         $display("ERROR: hresp still %b after the second error completed %t ns", hresp, $time);
         error = error + 1;
      end

      // --- denied, then a LEGAL access presented in P2 ---
      haddr  = 32'h00400000;
      htrans = 2'b10;
      hwrite = 1'b0;
      hprot  = 4'h2;
      hsmode = 1'b1;
      hsize  = 3'b010;

      @(posedge free_clk);
      #1;
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hprot  = 4'h0;
      hsmode = 1'b0;

      @(posedge free_clk);
      #1;                          // P2 -- issue an allowed M-mode read here
      haddr  = 32'h00400000;
      htrans = 2'b10;
      hwrite = 1'b0;
      hprot  = 4'h2;
      hsmode = 1'b0;               // {hprot[1],hsmode} = 1,0 -> Machine
      hsize  = 3'b010;

      @(posedge free_clk);
      #1;
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hprot  = 4'h0;

      if ((hresp === 1'b0) && (hreadyout === 1'b1)) begin
         $display("PASS:  legal transfer issued in P2 completes OK, uncontaminated %t ns", $time);
      end else begin
         $display("ERROR: legal transfer issued in P2 -- expected hresp=0/hreadyout=1, got %b/%b %t ns",
                  hresp, hreadyout, $time);
         error = error + 1;
      end

      @(posedge free_clk);
      #1;

      // Sanity: a legal M-mode access right after must still succeed OK.
      ahb_read(1, MACHINE, 32'h00400000, 32'h00000000, 2, 1, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
